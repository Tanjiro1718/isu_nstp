import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../../config/api_config.dart';
import '../../models/user_model.dart';

class AdminManageUsersScreen extends StatefulWidget {
  final UserModel? currentUser;

  const AdminManageUsersScreen({super.key, this.currentUser});

  @override
  _AdminManageUsersScreenState createState() => _AdminManageUsersScreenState();
}

class _AdminManageUsersScreenState extends State<AdminManageUsersScreen> {
  // Existing state variables
  List<dynamic> _users = [];
  bool _isLoading = true;
  final String apiUrl = ApiConfig.usersUrl;

  // State variables for Pending Approvals
  List<dynamic> _pendingUsers = [];
  bool _isLoadingPending = true;

  @override
  void initState() {
    super.initState();
    _fetchUsers();
    _fetchPendingUsers();
  }

  // =========================================================================
  // 1. ALL ACTIVE USERS (Fetch, Create, Delete)
  // =========================================================================

  Future<void> _fetchUsers() async {
    setState(() => _isLoading = true);
    try {
      final response = await http.get(Uri.parse('$apiUrl?is_active=true'));
      if (response.statusCode == 200) {
        setState(() {
          _users = json.decode(response.body);
          _isLoading = false;
        });
      } else {
        _showSnackBar('Failed to load users. Error: ${response.statusCode}', Colors.red);
        setState(() => _isLoading = false);
      }
    } catch (e) {
      _showSnackBar('Network error: $e', Colors.red);
      setState(() => _isLoading = false);
    }
  }

  Future<void> _createUser(
    String username,
    String email,
    String password,
    String role,
  ) async {
    try {
      final response = await http.post(
        Uri.parse(apiUrl),
        body: {
          'username': username,
          'email': email,
          'password': password,
          'role': role,
          'is_active': 'true',
        },
      );

      if (response.statusCode == 201 || response.statusCode == 200) {
        _showSnackBar('User $username created successfully!', Colors.green);
        _fetchUsers();
      } else {
        _showSnackBar('Failed: ${response.body}', Colors.red);
      }
    } catch (e) {
      _showSnackBar('Network error: $e', Colors.red);
    }
  }

  Future<void> _deleteUser(int userId) async {
    try {
      final response = await http.delete(Uri.parse('$apiUrl$userId/'));
      if (response.statusCode == 204 || response.statusCode == 200) {
        _showSnackBar('User deleted successfully', Colors.green);
        _fetchUsers();
      } else {
        _showSnackBar('Failed to delete user. ${_extractError(response)}', Colors.red);
      }
    } catch (e) {
      _showSnackBar('Network error: $e', Colors.red);
    }
  }

  // =========================================================================
  // 2. PENDING APPROVALS (Fetch, Approve, Reject)
  // =========================================================================

  Future<void> _fetchPendingUsers() async {
    setState(() => _isLoadingPending = true);
    try {
      final response = await http.get(Uri.parse('$apiUrl?is_active=false'));

      debugPrint("RAW PENDING USERS JSON: ${response.body}");
      
      if (response.statusCode == 200) {
        setState(() {
          _pendingUsers = json.decode(response.body);
          _isLoadingPending = false;
        });
      } else {
        setState(() => _isLoadingPending = false);
      }
    } catch (e) {
      setState(() => _isLoadingPending = false);
    }
  }

  Future<void> _approveUser(int userId) async {
    try {
      final response = await http.patch(
        Uri.parse('$apiUrl$userId/'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'is_active': true}),
      );

      if (response.statusCode == 200 || response.statusCode == 204) {
        _showSnackBar('User Approved', Colors.green);
        _fetchPendingUsers();
        _fetchUsers();
      } else {
        _showSnackBar('Failed to approve user. ${_extractError(response)}', Colors.red);
      }
    } catch (e) {
      _showSnackBar('Network error: $e', Colors.red);
    }
  }

  Future<void> _rejectUser(int userId, String username) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reject Registration?'),
        content: Text('This permanently deletes $username and removes them from pending approvals. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reject', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final response = await http.delete(Uri.parse('$apiUrl$userId/'));
      if (response.statusCode == 200 || response.statusCode == 204) {
        _showSnackBar('User Rejected', Colors.red);
        _fetchPendingUsers();
        _fetchUsers();
      } else {
        _showSnackBar('Failed to reject user. ${_extractError(response)}', Colors.red);
      }
    } catch (e) {
      _showSnackBar('Network error: $e', Colors.red);
    }
  }

  String _extractError(http.Response response) {
    try {
      final decoded = json.decode(response.body);
      if (decoded is Map) {
        final detail = decoded['detail'] ?? decoded['error'] ?? decoded['message'];
        if (detail != null) return detail.toString();
        final first = decoded.values.firstOrNull;
        if (first is List && first.isNotEmpty) return first.first.toString();
        if (first != null) return first.toString();
      }
    } catch (_) {
      // fall through to raw body
    }
    final body = response.body.trim();
    return body.isEmpty ? '(HTTP ${response.statusCode})' : body;
  }

  void _showIdPictureDialog(String imageUrl, String studentId) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text("ID Verification: $studentId", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            ),
            InteractiveViewer(
              child: Image.network(
                imageUrl, 
                headers: const {"ngrok-skip-browser-warning": "69420"},
                fit: BoxFit.contain,
                loadingBuilder: (context, child, loadingProgress) {
                  if (loadingProgress == null) return child;
                  return const Padding(
                    padding: EdgeInsets.all(32.0),
                    child: CircularProgressIndicator(),
                  );
                },
                errorBuilder: (context, error, stackTrace) {
                  debugPrint("Error loading image from $imageUrl: $error");
                  return const Padding(
                    padding: EdgeInsets.all(32.0),
                    child: Text("Failed to load image from server.", style: TextStyle(color: Colors.red)),
                  );
                },
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("Close"),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // =========================================================================
  // 3. UI BUILDERS & DIALOGS
  // =========================================================================

  void _showSnackBar(String message, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), backgroundColor: color));
  }

  void _showAddUserDialog() {
    final dialogFormKey = GlobalKey<FormState>();
    final usernameController = TextEditingController();
    final emailController = TextEditingController();
    final passwordController = TextEditingController();

    // Students are deliberately not creatable here - see the role dropdown.
    String selectedRole = 'instructor';
    bool obscurePassword = true; 

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              title: const Text('Add New User'),
              content: Form(
                key: dialogFormKey,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextFormField(
                        controller: usernameController,
                        decoration: const InputDecoration(labelText: 'Username'),
                        validator: (v) => v!.isEmpty ? 'Required' : null,
                      ),
                      TextFormField(
                        controller: emailController,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(
                          labelText: 'Verified ISU Email',
                          hintText: 'name@isu.edu.ph',
                          helperText: 'Must end with @isu.edu.ph',
                        ),
                        validator: (v) {
                          if (v!.trim().isEmpty) return 'Email is required';
                          if (!v.trim().endsWith('@isu.edu.ph')) return 'Must use @isu.edu.ph domain';
                          return null;
                        },
                      ),
                      TextFormField(
                        controller: passwordController,
                        decoration: InputDecoration(
                          labelText: 'Password',
                          suffixIcon: IconButton(
                            icon: Icon(
                              obscurePassword ? Icons.visibility_off : Icons.visibility,
                              color: Colors.grey,
                            ),
                            onPressed: () {
                              setStateDialog(() {
                                obscurePassword = !obscurePassword;
                              });
                            },
                          ),
                        ),
                        obscureText: obscurePassword,
                        validator: (v) => v!.isEmpty ? 'Required' : null,
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                        initialValue: selectedRole,
                        decoration: const InputDecoration(labelText: 'Role'),
                        // Staff roles only. Students register themselves so the
                        // ID-picture and email-verification steps still run;
                        // an account minted here would skip both.
                        items: ['instructor', 'director', 'admin']
                            .map((role) => DropdownMenuItem(value: role, child: Text(role.toUpperCase())))
                            .toList(),
                        onChanged: (value) => setStateDialog(() => selectedRole = value!),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Students cannot be added here. They sign up through '
                        'the app, then appear in this list for approval.',
                        style: TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                      const SizedBox(height: 16),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () {
                    if (dialogFormKey.currentState!.validate()) {
                      Navigator.pop(context);
                      _createUser(
                        usernameController.text.trim(),
                        emailController.text.trim(),
                        passwordController.text,
                        selectedRole,
                      );
                    }
                  },
                  child: const Text('Create User'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text("Manage Users"),
          backgroundColor: Colors.deepPurple,
          foregroundColor: Colors.white,
          bottom: const TabBar(
            indicatorColor: Colors.white,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white70,
            tabs: [
              Tab(icon: Icon(Icons.people), text: "All Users"),
              Tab(icon: Icon(Icons.pending_actions), text: "Pending Approvals"),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            // --- TAB 1: ALL ACTIVE USERS ---
            _isLoading
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: _fetchUsers,
                    child: ListView.builder(
                      itemCount: _users.length,
                      itemBuilder: (context, index) {
                        final user = _users[index];

                        bool isSelf = widget.currentUser != null && user['username'] == widget.currentUser!.username;
                        String role = (user['role'] ?? 'Unknown').toString().toLowerCase();
                        bool isAdminRole = role == 'admin';
                        bool cannotDelete = isSelf || isAdminRole;

                        // Display strings for extra details
                        String displayRole = role.toUpperCase();
                        String? studentId = user['student_id'];
                        String? course = user['course'];
                        String? section = user['section'];

                        return Card(
                          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor: cannotDelete ? Colors.blue.shade100 : Colors.deepPurple.shade100,
                              child: Icon(
                                cannotDelete ? Icons.admin_panel_settings : Icons.person,
                                color: Colors.grey.shade600,
                              ),
                            ),
                            title: Row(
                              children: [
                                Text(user['username'] ?? 'Unknown', style: const TextStyle(fontWeight: FontWeight.bold)),
                                const SizedBox(width: 8),
                                if (isSelf) 
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(color: Colors.blue, borderRadius: BorderRadius.circular(4)),
                                    child: const Text("YOU", style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                                  )
                                else 
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: isAdminRole ? Colors.grey.shade700 : Colors.deepPurple.shade300, 
                                      borderRadius: BorderRadius.circular(4)
                                    ),
                                    child: Text(displayRole, style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                                  ),
                              ],
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(user['email'] ?? 'No email provided', style: const TextStyle(fontSize: 12)),
                                if (role == 'student' && studentId != null)
                                  Text('ID: $studentId | $course - $section', style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
                              ],
                            ),
                            trailing: cannotDelete
                                ? Tooltip(
                                    message: "Admin deletion is disabled to prevent system lockout.",
                                    child: Padding(padding: EdgeInsets.all(8.0), child: Icon(Icons.shield, color: Colors.grey.shade600)),
                                  )
                                : IconButton(
                                    icon: Icon(Icons.delete, color: Colors.grey.shade600),
                                    onPressed: () {
                                      showDialog(
                                        context: context,
                                        builder: (ctx) => AlertDialog(
                                          title: const Text('Delete User?'),
                                          content: Text('Are you sure you want to delete ${user['username']}?'),
                                          actions: [
                                            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                                            ElevatedButton(
                                              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                                              onPressed: () {
                                                Navigator.pop(ctx);
                                                _deleteUser(user['id']);
                                              },
                                              child: const Text('Delete', style: TextStyle(color: Colors.white)),
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                          ),
                        );
                      },
                    ),
                  ),

            // --- TAB 2: PENDING APPROVALS ---
            _isLoadingPending
                ? const Center(child: CircularProgressIndicator())
                : _pendingUsers.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.check_circle_outline, size: 64, color: Colors.grey.shade400),
                            const SizedBox(height: 16),
                            const Text("No pending users to approve.", style: TextStyle(fontSize: 16, color: Colors.grey)),
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _fetchPendingUsers,
                        child: ListView.builder(
                          padding: const EdgeInsets.all(16),
                          itemCount: _pendingUsers.length,
                          itemBuilder: (context, index) {
                            final user = _pendingUsers[index];

                            debugPrint("👉 DJANGO USER DATA FOR ${user['username']}: $user");
                            final int userId = user['id'];
                            final username = user['username'] ?? 'Unknown ID';
                            final email = user['email'] ?? 'No Email';
                            
                            // Rely strictly on Django's new robust image URL handling
                            String? rawImageUrl = user['id_picture_front'];
                            String? finalImageUrl;

                            if (rawImageUrl != null && rawImageUrl.toString().trim().isNotEmpty) {
                              finalImageUrl = rawImageUrl.toString().trim();
                              
                              // Fallback string manipulation just in case Django didn't build the absolute URI correctly
                              if (!finalImageUrl.startsWith('http')) {
                                if (!finalImageUrl.startsWith('/')) {
                                  finalImageUrl = '/$finalImageUrl';
                                }
                                
                                Uri apiUri = Uri.parse(ApiConfig.baseUrl);
                                String rootUrl = '${apiUri.scheme}://${apiUri.host}';
                                if (apiUri.hasPort) {
                                  rootUrl = '$rootUrl:${apiUri.port}';
                                }
                                
                                finalImageUrl = '$rootUrl$finalImageUrl';
                              }
                            }

                            return Card(
                              elevation: 3,
                              margin: const EdgeInsets.only(bottom: 16),
                              child: Padding(
                                padding: const EdgeInsets.all(16.0),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Icon(Icons.person, color: Colors.grey.shade600),
                                        const SizedBox(width: 8),
                                        Text(username, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Text(email, style: TextStyle(color: Colors.grey.shade700)),
                                    
                                    // Display course/section data if available
                                    if (user['course'] != null)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 4.0),
                                        child: Text('${user['course']} - ${user['section'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w500)),
                                      ),
                                    
                                    const Divider(height: 24),
                                    
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        TextButton.icon(
                                          icon: const Icon(Icons.image),
                                          label: const Text("View ID"),
                                          onPressed: () {
                                            if (finalImageUrl != null) {
                                              _showIdPictureDialog(finalImageUrl, username);
                                            } else {
                                              _showSnackBar('No ID image provided.', Colors.orange);
                                            }
                                          },
                                        ),
                                        Row(
                                          children: [
                                            OutlinedButton(
                                              style: OutlinedButton.styleFrom(foregroundColor: Colors.red, side: const BorderSide(color: Colors.red)),
                                              onPressed: () => _rejectUser(userId, username),
                                              child: const Text("Reject"),
                                            ),
                                            const SizedBox(width: 8),
                                            ElevatedButton(
                                              style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
                                              onPressed: () => _approveUser(userId),
                                              child: const Text("Approve"),
                                            ),
                                          ],
                                        ),
                                      ],
                                    )
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
          ],
        ),
        floatingActionButton: FloatingActionButton(
          backgroundColor: Colors.deepPurple,
          foregroundColor: Colors.white,
          onPressed: _showAddUserDialog,
          child: const Icon(Icons.add),
        ),
      ),
    );
  }
}