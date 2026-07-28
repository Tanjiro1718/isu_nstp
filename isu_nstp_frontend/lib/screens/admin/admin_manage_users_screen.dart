import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../../config/api_config.dart';
import '../../models/user_model.dart';

class AdminManageUsersScreen extends StatefulWidget {
  final UserModel? currentUser;

  const AdminManageUsersScreen({Key? key, this.currentUser}) : super(key: key);

  @override
  _AdminManageUsersScreenState createState() => _AdminManageUsersScreenState();
}

class _AdminManageUsersScreenState extends State<AdminManageUsersScreen> {
  List<dynamic> _users = [];
  bool _isLoading = true;

  final String apiUrl = ApiConfig.usersUrl;

  @override
  void initState() {
    super.initState();
    _fetchUsers();
  }

  // --- 1. READ: Fetch all users from Django ---
  Future<void> _fetchUsers() async {
    setState(() => _isLoading = true);
    try {
      final response = await http.get(Uri.parse(apiUrl));
      if (response.statusCode == 200) {
        setState(() {
          _users = json.decode(response.body);
          _isLoading = false;
        });
      } else {
        _showSnackBar(
          'Failed to load users. Error: ${response.statusCode}',
          Colors.red,
        );
        setState(() => _isLoading = false);
      }
    } catch (e) {
      _showSnackBar('Network error: $e', Colors.red);
      setState(() => _isLoading = false);
    }
  }

  // --- 2. CREATE: Add a new user to Django ---
  Future<void> _createUser(
    String username,
    String email,
    String password,
    String role,
    String campus,
  ) async {
    try {
      final response = await http.post(
        Uri.parse(apiUrl),
        body: {
          'username': username,
          'email': email,
          'password': password,
          'role': role,
          'campus': campus, // Now dynamically passed from the dropdown!
        },
      );

      if (response.statusCode == 201 || response.statusCode == 200) {
        _showSnackBar('User $username created successfully!', Colors.green);
        _fetchUsers(); // Refresh the list automatically
      } else {
        // This will print the exact Django validation error to the screen
        _showSnackBar('Failed: ${response.body}', Colors.red);
      }
    } catch (e) {
      _showSnackBar('Network error: $e', Colors.red);
    }
  }

  // --- 3. DELETE: Remove a user from Django ---
  Future<void> _deleteUser(int userId) async {
    try {
      final response = await http.delete(Uri.parse('$apiUrl$userId/'));
      if (response.statusCode == 204 || response.statusCode == 200) {
        _showSnackBar('User deleted successfully', Colors.green);
        _fetchUsers();
      } else {
        _showSnackBar('Failed to delete user.', Colors.red);
      }
    } catch (e) {
      _showSnackBar('Network error: $e', Colors.red);
    }
  }

  // UI Dialog to Add New User
  void _showAddUserDialog() {
    final dialogFormKey = GlobalKey<FormState>();
    final usernameController = TextEditingController();
    final emailController = TextEditingController();
    final passwordController = TextEditingController();

    String selectedRole = 'student';
    bool obscurePassword =
        true; // Added state variable for toggling password visibility

    // 🔴 FIX: Nakatugma na ito nang eksakto sa kaliwang bahagi ng iyong Django CAMPUS_CHOICES!
    String selectedCampus = 'echague';
    final List<String> campusOptions = [
      'echague',
      'cauayan',
      'ilagan',
      'cabagan',
    ];

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
                        decoration: const InputDecoration(
                          labelText: 'Username',
                        ),
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
                          if (!v.trim().endsWith('@isu.edu.ph'))
                            return 'Must use @isu.edu.ph domain';
                          return null;
                        },
                      ),
                      TextFormField(
                        controller: passwordController,
                        decoration: InputDecoration(
                          labelText: 'Password',
                          suffixIcon: IconButton(
                            icon: Icon(
                              obscurePassword
                                  ? Icons.visibility_off
                                  : Icons.visibility,
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
                        value: selectedRole,
                        decoration: const InputDecoration(labelText: 'Role'),
                        items: ['student', 'instructor', 'director', 'admin']
                            .map(
                              (role) => DropdownMenuItem(
                                value: role,
                                child: Text(role.toUpperCase()),
                              ),
                            )
                            .toList(),
                        onChanged: (value) =>
                            setStateDialog(() => selectedRole = value!),
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                        value: selectedCampus,
                        decoration: const InputDecoration(labelText: 'Campus'),
                        items: campusOptions
                            .map(
                              (campus) => DropdownMenuItem(
                                value: campus,
                                // .toUpperCase() here just makes it look pretty for the user,
                                // but it sends the exact 'value' to Django
                                child: Text(campus.toUpperCase()),
                              ),
                            )
                            .toList(),
                        onChanged: (value) =>
                            setStateDialog(() => selectedCampus = value!),
                      ),
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
                        selectedCampus, // Passing the selected campus dynamically
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

  void _showSnackBar(String message, Color color) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message), backgroundColor: color));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Manage Users"),
        backgroundColor: Colors.deepPurple,
        foregroundColor: Colors.white,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _fetchUsers,
              child: ListView.builder(
                itemCount: _users.length,
                itemBuilder: (context, index) {
                  final user = _users[index];

                  // 🛡️ SECURITY CHECKS
                  bool isSelf =
                      widget.currentUser != null &&
                      user['username'] == widget.currentUser!.username;
                  bool isAdminRole =
                      (user['role'] ?? '').toString().toLowerCase() == 'admin';
                  bool cannotDelete = isSelf || isAdminRole;

                  return Card(
                    margin: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: cannotDelete
                            ? Colors.blue.shade100
                            : Colors.deepPurple.shade100,
                        child: Icon(
                          cannotDelete
                              ? Icons.admin_panel_settings
                              : Icons.person,
                          color: cannotDelete ? Colors.blue : Colors.deepPurple,
                        ),
                      ),
                      title: Row(
                        children: [
                          Text(
                            user['username'] ?? 'Unknown',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          if (isSelf) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.blue,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text(
                                "YOU",
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ] else if (isAdminRole) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.grey.shade700,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text(
                                "ADMIN",
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      subtitle: Text(
                        "Role: ${(user['role'] ?? 'None').toString().toUpperCase()} | Campus: ${user['campus'] ?? 'N/A'}",
                      ),
                      trailing: cannotDelete
                          ? const Tooltip(
                              message:
                                  "Admin deletion is disabled to prevent system lockout.",
                              child: Padding(
                                padding: EdgeInsets.all(8.0),
                                child: Icon(
                                  Icons.shield,
                                  color: Colors.blueAccent,
                                ),
                              ),
                            )
                          : IconButton(
                              icon: const Icon(Icons.delete, color: Colors.red),
                              onPressed: () {
                                showDialog(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    title: const Text('Delete User?'),
                                    content: Text(
                                      'Are you sure you want to delete ${user['username']}?',
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(ctx),
                                        child: const Text('Cancel'),
                                      ),
                                      ElevatedButton(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: Colors.red,
                                        ),
                                        onPressed: () {
                                          Navigator.pop(ctx);
                                          _deleteUser(user['id']);
                                        },
                                        child: const Text(
                                          'Delete',
                                          style: TextStyle(color: Colors.white),
                                        ),
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
      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.deepPurple,
        foregroundColor: Colors.white,
        onPressed: _showAddUserDialog,
        child: const Icon(Icons.add),
      ),
    );
  }
}
