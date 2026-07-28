from django.shortcuts import render
from rest_framework.views import APIView
from rest_framework.response import Response
from rest_framework import status
from django.contrib.auth import authenticate
from .models import User, AttendanceSession, AttendanceRecord, StudentProfile
from .serializers import UserSerializer
from .serializers import AttendanceLogSerializer, SessionSerializer
from rest_framework.permissions import AllowAny
from geopy.distance import geodesic
from rest_framework import viewsets
from .models import SystemSettings
from .serializers import SystemSettingsSerializer
from django.contrib.auth import get_user_model

User = get_user_model()

class PasswordResetAPIView(APIView):
    def post(self, request):
        username = request.data.get('username')
        email = request.data.get('email')
        # 1. Check if both fields were sent
        if not username or not email:
            return Response({'detail': 'Username and email are required.'}, status=status.HTTP_400_BAD_REQUEST)

        # 2. Enforce ISU Domain on the backend as a double-security measure
        if not email.endswith('@isu.edu.ph'):
            return Response({'detail': 'Only @isu.edu.ph emails are allowed.'}, status=status.HTTP_403_FORBIDDEN)

        try:
            # 3. Find the user in the database
            user = User.objects.get(username=username, email=email)
            
            # 4. Generate a temporary password (for your prototype)
            # In a fully deployed app, you would send an email link here instead.
            temp_password = "ISU-" + User.objects.make_random_password(length=6)
            user.set_password(temp_password)
            user.save()
            
            # Print to terminal so YOU (the developer) can see it and test it
            print(f"PASSWORD RESET SUCCESS: User {username} temporary password is: {temp_password}")

            return Response({'detail': 'Password reset successful.'}, status=status.HTTP_200_OK)
            
        except User.DoesNotExist:
            return Response({'detail': 'No account found matching this username and verified email.'}, status=status.HTTP_404_NOT_FOUND)

class LoginAPIView(APIView):
    def post(self, request):
        username = request.data.get('username') or request.POST.get('username')
        password = request.data.get('password') or request.POST.get('password')

        print(f"--- Login Attempt Received ---")
        print(f"Username typed: '{username}'")
        print(f"Password typed: '{password}'")

        try:
            # 1. Fetch the user directly from your custom database table
            user = User.objects.get(username=username)
            print(f"User found in database! Hashed password: {user.password}")

            # 2. Check the password manually using Django's internal hashing comparison
            if user.check_password(password):
                print("Password verified successfully!")
                
                # Check if account is active
                if not user.is_active:
                    return Response({'message': 'Account is disabled'}, status=status.HTTP_400_BAD_REQUEST)

                # 3. Use UserSerializer to serialize the complete user data profile.
                # This ensures ALL fields (email, names, etc.) are sent safely to Flutter.
                user_data = UserSerializer(user).data

                return Response({
                    'message': 'Login successful',
                    'user': user_data  # Passes the complete serialized dictionary layout
                }, status=status.HTTP_200_OK)
            else:
                print("Password check failed.")
                return Response({'message': 'Invalid password'}, status=status.HTTP_400_BAD_REQUEST)

        except User.DoesNotExist:
            print("Username not found in the database.")
            return Response({'message': 'Username does not exist'}, status=status.HTTP_400_BAD_REQUEST)
    

class ProcessCheckInAPI(APIView):
    permission_classes = [AllowAny]

    def post(self, request):
        session_id = request.data.get('session_id')
        student_id = request.data.get('student_id')
        
        # Guard against empty or missing data to prevent app crashes
        if not session_id or not student_id or not request.data.get('latitude') or not request.data.get('longitude'):
            return Response({"status": "error", "message": "Missing required parameters"}, status=400)
            
        try:
            stud_lat = float(request.data.get('latitude'))
            stud_lng = float(request.data.get('longitude'))
        except (ValueError, TypeError):
            return Response({"status": "error", "message": "Invalid coordinates format"}, status=400)
        
        try:
            session = AttendanceSession.objects.get(id=session_id)
            student_user = User.objects.get(id=student_id)
            student_profile, _ = StudentProfile.objects.get_or_create(
                user=student_user,
                defaults={
                    'student_id': f'{student_user.username}-{student_user.id}',
                    'component': 'CWTS',
                    'section_code': 'CWTS-1A',
                },
            )
            
            # Calculate distance between student and session center point
            session_coords = (session.target_latitude, session.target_longitude)
            student_coords = (stud_lat, stud_lng)
            distance = geodesic(session_coords, student_coords).meters
            
            if distance <= session.radius_meters:
                selfie_file = request.FILES.get('selfie')
                mode = request.data.get('mode') or ('online' if selfie_file else 'offline')
                # Creates the record in your MySQL database
                AttendanceRecord.objects.create(
                    session=session,
                    student=student_profile,
                    student_latitude=stud_lat,
                    student_longitude=stud_lng,
                    status='Present',
                    mode=mode,
                    student_address=request.data.get('address') or request.data.get('student_address'),
                    selfie_verified=bool(selfie_file),
                    selfie_image=selfie_file,
                )
                return Response({
                    "status": "success", 
                    "message": f"Attendance recorded successfully! You are {distance:.1f}m away."
                })
            else:
                return Response({
                    "status": "failed", 
                    "message": f"Out of bounds! You are {distance:.1f}m away, but the limit is {session.radius_meters}m."
                }, status=400)
                
        except AttendanceSession.DoesNotExist:
            return Response({"status": "error", "message": "Attendance session not found"}, status=404)
        except User.DoesNotExist:
            return Response({"status": "error", "message": "Student account not found"}, status=404)

class AttendanceLogAPIView(APIView):
    permission_classes = [AllowAny]

    def get(self, request):
        records = AttendanceRecord.objects.select_related(
            'student__user',
            'session',
            'session__instructor',
        ).order_by('-timestamp')

        instructor_id = request.query_params.get('instructor_id')
        if instructor_id:
            records = records.filter(session__instructor_id=instructor_id)

        serializer = AttendanceLogSerializer(records, many=True, context={'request': request})
        return Response(serializer.data)

class AttendanceSessionAPIView(APIView):
    permission_classes = [AllowAny]

    def get(self, request):
        session = AttendanceSession.objects.order_by('-date_time', '-id').first()
        if not session:
            return Response({"message": "No active attendance session found"}, status=404)

        serializer = SessionSerializer(session)
        return Response(serializer.data)

    def post(self, request):
        instructor_id = request.data.get('instructor')
        if not instructor_id:
            return Response({"message": "Instructor is required"}, status=400)

        data = request.data.copy()
        data.setdefault('title', 'NSTP Attendance Session')

        serializer = SessionSerializer(data=data)
        if serializer.is_valid():
            serializer.save()
            return Response(serializer.data, status=201)
        return Response(serializer.errors, status=400)

class UserViewSet(viewsets.ModelViewSet):
    queryset = User.objects.all().order_by('-date_joined') # Shows newest users first
    serializer_class = UserSerializer

class SystemSettingsAPIView(APIView):
    def get(self, request):
        settings, created = SystemSettings.objects.get_or_create(id=1)
        serializer = SystemSettingsSerializer(settings)
        return Response(serializer.data)

    def put(self, request):
        settings, created = SystemSettings.objects.get_or_create(id=1)
        serializer = SystemSettingsSerializer(settings, data=request.data, partial=True)
        if serializer.is_valid():
            serializer.save()
            return Response(serializer.data)
        return Response(serializer.errors, status=status.HTTP_400_BAD_REQUEST)
