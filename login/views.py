import re
import secrets
import string
from django.shortcuts import render, redirect
from django.db import connection
from django.contrib import messages
from django.http import JsonResponse
from django.contrib.auth.hashers import make_password, check_password

from login.decorators import permission_required_sp
from login.utils import get_session_user, save_upload, dispatch_email, insertuserlog


def generate_random_password(length=10):
    chars = string.ascii_letters + string.digits + "!@#$%^&*"
    return ''.join(secrets.choice(chars) for _ in range(length))


def _load_user_menus(cursor, user_detail_id):
    """Call SP_GET_USER_MENUS and return the menu list for the session."""
    menu_cursor = cursor.connection.cursor()
    cursor.callproc('SP_GET_USER_MENUS', [str(user_detail_id), menu_cursor])

    permitted_menus = []
    for row in menu_cursor:
        permitted_menus.append({
            'id': row[0],
            'title': row[1],
            'url_name': row[2],
            'parent_id': row[3],
            'icon': row[4]
        })
    menu_cursor.close()
    return permitted_menus


def _notify_password_changed(request):
    """Email the registered address a password-change notification (never raises)."""
    email = request.session.get('JB_Email')
    if not email:
        return False
    return dispatch_email(
        "Password Changed",
        "Your password has been changed successfully.\n\n"
        f"User ID: {request.session.get('JB_UserID', '')}\n\n"
        "If you did not perform this change, contact your administrator immediately.",
        email,
    )



# 1. DASHBOARD VIEW
def dashboard(request):
    if not get_session_user(request):
        return redirect('login_page')
    return render(request, 'login/dashboard.html')


# 1b. LOGOUT VIEW
def logout_view(request):
    request.session.flush()
    return redirect('login_page')


# 2. LOGIN VIEW
def login_view(request):
    if request.method == 'POST':
        user_id = request.POST.get('user_id')
        password = request.POST.get('password')

        with connection.cursor() as django_cursor:
            cursor = django_cursor.connection.cursor()

            user_detail_id = cursor.var(int)
            hashed_pwd = cursor.var(str)
            is_first_login = cursor.var(int)
            status = cursor.var(str)
            failed_attempts = cursor.var(int)
            success = cursor.var(int)
            msg = cursor.var(str)

            cursor.callproc('SP_AUTHENTICATE_USER', [
                user_id, user_detail_id, hashed_pwd, is_first_login, status, failed_attempts, success, msg
            ])

            if success.getvalue() == 1:
                stored_hashed = hashed_pwd.getvalue()
                if not stored_hashed or '$' not in stored_hashed:
                    messages.error(
                        request,
                        "The password stored for this account is invalid or incomplete. Please use 'Forgot password?' to reset it."
                    )
                elif check_password(password, stored_hashed):
                    request.session['JB_UserDetailID'] = user_detail_id.getvalue()
                    request.session['JB_UserID'] = user_id

                    # Load User Menu Permissions
                    request.session['USER_MENUS'] = _load_user_menus(cursor, user_detail_id.getvalue())

                    # Load basic profile (name + photo) for the topbar.
                    try:
                        user_name = cursor.var(str)
                        email = cursor.var(str)
                        image_path = cursor.var(str)
                        role_name = cursor.var(str)
                        cursor.callproc('SP_GET_USER_DETAILS', [
                            user_detail_id.getvalue(), user_name, email,
                            image_path, role_name, success
                        ])
                        request.session['JB_FullName'] = user_name.getvalue()
                        request.session['JB_ImagePath'] = image_path.getvalue()
                        request.session['JB_RoleName'] = role_name.getvalue()
                        request.session['JB_Email'] = email.getvalue()
                    except Exception:
                        request.session['JB_FullName'] = user_id

                    if is_first_login.getvalue() == 1:
                        # Temporary-password / first-login account: lock the session
                        # to the change-password page only - no other menu access
                        # until the password has been changed.
                        request.session['FORCE_PW_CHANGE'] = 1
                        request.session['USER_MENUS'] = [{
                            'id': 0,
                            'title': 'Change Password',
                            'url_name': 'force_change_password',
                            'parent_id': None,
                            'icon': 'bi-key',
                        }]
                        return redirect('force_change_password')

                    request.session.pop('FORCE_PW_CHANGE', None)
                    return redirect('dashboard')
                else:
                    messages.error(request, "Invalid User ID or Password.")
            else:
                messages.error(request, msg.getvalue() if msg.getvalue() else "Invalid Credentials or Account Locked.")

    return render(request, 'login/login_register.html')


# 3. USER REGISTRATION VIEW
def register_user(request):
    if request.method == 'POST':
        fullname = request.POST.get('fullname')
        mobile = request.POST.get('mobile')
        email = request.POST.get('email')
        nid = request.POST.get('nid')

        try:
            # Registration attachments: JPG/PNG only, max 3 MB.
            file_path = save_upload(request, 'attachments', 'attachment',
                                     ('.jpg', '.jpeg', '.png'), 3 * 1024 * 1024)
        except ValueError as exc:
            messages.error(request, str(exc))
            return redirect('login_page')

        with connection.cursor() as django_cursor:
            cursor = django_cursor.connection.cursor()

            success = cursor.var(int)
            msg = cursor.var(str)

            cursor.callproc('SP_SUBMIT_REGISTRATION', [
                fullname, mobile, email, nid, file_path, success, msg
            ])

            if success.getvalue() == 1:
                messages.success(request, msg.getvalue())
            else:
                messages.error(request, msg.getvalue())

    return redirect('login_page')


# 4. PENDING REGISTRATION VIEW
@permission_required_sp('pending_registration')
def pending_registration(request):
    pending_users = []
    with connection.cursor() as django_cursor:
        cursor = django_cursor.connection.cursor()
        reg_cursor = cursor.connection.cursor()

        cursor.callproc('SP_GET_PENDING_REGISTRATIONS', [reg_cursor])

        for row in reg_cursor:
            pending_users.append({
                'registration_id': row[0],
                'fullname': row[1],
                'mobile': row[2],
                'email': row[3],
                'nid': row[4],
                'attachment_path': row[5],
            })
        reg_cursor.close()

    return render(request, 'login/pending_registration.html', {'pending_users': pending_users})


# 5. AUDIT TRAIL LOG VIEW
@permission_required_sp('audit_trail')
def audit_trail(request):
    audit_logs = []
    with connection.cursor() as django_cursor:
        cursor = django_cursor.connection.cursor()
        log_cursor = cursor.connection.cursor()

        cursor.callproc('SP_GET_AUDIT_LOGS', [log_cursor])

        for row in log_cursor:
            audit_logs.append({
                'log_id': row[0],
                'timestamp': row[1],
                'user_id': row[2],
                'role_name': row[3],
                'action_type': row[4],
                'url_path': row[5],
                'ip_address': row[6],
                'response_status': row[7],
            })
        log_cursor.close()

    return render(request, 'login/audit_trail.html', {'audit_logs': audit_logs})


# 6. FORCE CHANGE PASSWORD VIEW
def force_change_password(request):
    user_detail_id = get_session_user(request)
    if not user_detail_id:
        return redirect('login_page')

    if request.method == 'POST':
        new_pwd = request.POST.get('new_password')
        confirm_pwd = request.POST.get('confirm_password')

        if new_pwd != confirm_pwd:
            messages.error(request, "Passwords do not match!")
            return render(request, 'login/force_change_password.html')

        hashed_pwd = make_password(new_pwd)

        with connection.cursor() as django_cursor:
            cursor = django_cursor.connection.cursor()

            success = cursor.var(int)
            msg = cursor.var(str)

            cursor.callproc('SP_CHANGE_PASSWORD', [user_detail_id, hashed_pwd, success, msg])

            if success.getvalue() == 1:
                _notify_password_changed(request)
                request.session.pop('FORCE_PW_CHANGE', None)

                # Grant the user their real menu permissions now that the
                # password has been changed.
                request.session['USER_MENUS'] = _load_user_menus(cursor, user_detail_id)

                messages.success(
                    request,
                    "Your password has been changed successfully. "
                    "You now have access to your menu permissions."
                )
                return redirect('dashboard')
            else:
                messages.error(request, msg.getvalue())

    return render(request, 'login/force_change_password.html')


# 7. CHANGE PASSWORD VIEW
def change_password(request):
    user_detail_id = get_session_user(request)
    if not user_detail_id:
        return redirect('login_page')

    if request.session.get('FORCE_PW_CHANGE'):
        return redirect('force_change_password')

    if request.method == 'POST':
        new_pwd = request.POST.get('new_password')
        confirm_pwd = request.POST.get('confirm_password')

        if new_pwd != confirm_pwd:
            messages.error(request, "Passwords do not match.")
            return render(request, 'login/change_password.html')

        hashed_pwd = make_password(new_pwd)

        with connection.cursor() as django_cursor:
            cursor = django_cursor.connection.cursor()

            success = cursor.var(int)
            msg = cursor.var(str)

            cursor.callproc('SP_CHANGE_USER_PASSWORD', [user_detail_id, '', hashed_pwd, success, msg])

            if success.getvalue() == 1:
                _notify_password_changed(request)
                messages.success(request, "Password updated successfully. A confirmation has been sent to your registered email.")
                return redirect('dashboard')
            else:
                messages.error(request, msg.getvalue())

    return render(request, 'login/change_password.html')


# 8. FORGET PASSWORD VIEW
def forget_password(request):
    if request.method == 'POST':
        user_id = request.POST.get('user_id')
        email = request.POST.get('email')

        temp_pwd = generate_random_password()
        hashed_pwd = make_password(temp_pwd)

        # Email first — only reset the password in the DB when the mail is
        # actually delivered, otherwise the user would be locked out.
        email_sent = dispatch_email(
            "Password Reset Request",
            "Your password has been reset successfully.\n\n"
            f"User ID: {user_id}\nTemporary Password: {temp_pwd}\n\n"
            "Please login and update your password immediately. "
            "If you did not request this reset, contact your administrator.",
            email,
        )
        if not email_sent:
            messages.error(request, "Unable to send the temporary password email. Please verify your email address and try again.")
            return render(request, 'login/forget_password.html')

        with connection.cursor() as django_cursor:
            cursor = django_cursor.connection.cursor()

            reset_user_detail_id = cursor.var(int)
            success = cursor.var(int)
            msg = cursor.var(str)

            cursor.callproc('SP_FORGOT_PASSWORD_RESET', [
                user_id, email, hashed_pwd, reset_user_detail_id, success, msg
            ])

            if success.getvalue() == 1:
                messages.success(request, "Email sent successfully. A temporary password has been sent to your registered email address.")
                return render(request, 'login/forget_password.html')
            else:
                messages.error(request, msg.getvalue())

    return render(request, 'login/forget_password.html')


# 9. MANAGER DASHBOARD VIEW
@permission_required_sp('manager_dashboard')
def manager_dashboard(request):
    pending_users = []
    locked_users = []
    active_users = []

    with connection.cursor() as django_cursor:
        cursor = django_cursor.connection.cursor()

        pending_cur = cursor.connection.cursor()
        locked_cur = cursor.connection.cursor()
        active_cur = cursor.connection.cursor()

        cursor.callproc('SP_GET_PENDING_REGISTRATIONS', [pending_cur])
        cursor.callproc('SP_GET_LOCKED_USERS', [locked_cur])
        cursor.callproc('SP_GET_ACTIVE_USERS', [active_cur])

        for row in pending_cur:
            pending_users.append({
                'registration_id': row[0],
                'fullname': row[1],
                'mobile': row[2],
                'email': row[3],
                'nid': row[4],
                'attachment_path': row[5],
            })
        pending_cur.close()

        for row in locked_cur:
            locked_users.append({
                'user_id': row[0],
                'fullname': row[1],
                'email': row[2],
                'status': row[3],
                'failed_attempts': row[4],
            })
        locked_cur.close()

        for row in active_cur:
            active_users.append({
                'user_id': row[0],
                'fullname': row[1],
                'mobile': row[2],
                'email': row[3],
                'role_name': row[4],
                'image_path': row[5],
                'status': row[6],
                'created_at': row[7],
            })
        active_cur.close()

    return render(request, 'login/manager_dashboard.html', {
        'pending_users': pending_users,
        'locked_users': locked_users,
        'active_users': active_users,
    })


# 10. APPROVE REGISTRATION VIEW
@permission_required_sp('approve_user')
def approve_user(request, reg_id):
    manager_user_id = get_session_user(request)
    temp_pwd = generate_random_password()
    hashed_pwd = make_password(temp_pwd)

    with connection.cursor() as django_cursor:
        cursor = django_cursor.connection.cursor()

        gen_user_id = cursor.var(str)
        user_email = cursor.var(str)
        success = cursor.var(int)
        msg = cursor.var(str)

        cursor.callproc('SP_APPROVE_REGISTRATION', [
            reg_id, hashed_pwd, manager_user_id, gen_user_id, user_email, success, msg
        ])

        if success.getvalue() == 1:
            email_sent = dispatch_email(
                "Account Approved - Access Credentials",
                f"Your registration is approved.\nUser ID: {gen_user_id.getvalue()}\nTemporary Password: {temp_pwd}",
                user_email.getvalue(),
            )
            if email_sent:
                messages.success(request, f"User Approved by Manager. User ID: {gen_user_id.getvalue()} and credentials emailed.")
            else:
                messages.error(request, f"User Approved with User ID {gen_user_id.getvalue()}, but the credential email could NOT be sent to {user_email.getvalue()}.")
        else:
            messages.error(request, msg.getvalue())

    return redirect('manager_dashboard')


# 11. UNLOCK USER BY MANAGER VIEW
#      Delegates the unlock to the custom API() class. Expected contract:
#          api.UnlockUserByBankID(bank_id, hashed_temp_pwd)
#              -> {'success': bool, 'user_email': str, 'msg': str}
@permission_required_sp('unlock_user')
def unlock_user(request, user_id):
    temp_pwd = generate_random_password()
    hashed_pwd = make_password(temp_pwd)

    try:
        from login.api import API
        result = API().UnlockUserByBankID(user_id, hashed_pwd) or {}
        success = result.get('success')
        user_email = result.get('user_email')
        msg = result.get('msg')
    except Exception as exc:
        success, user_email, msg = 0, None, "API not ready: %s" % exc

    if success:
        email_sent = dispatch_email(
            "Account Unlocked - New Temporary Credentials",
            f"Your account has been unlocked by manager.\nUser ID: {user_id}\nTemporary Password: {temp_pwd}",
            user_email,
        )
        if email_sent:
            messages.success(request, f"Account {user_id} unlocked and credentials dispatched.")
        else:
            messages.error(request, f"Account {user_id} unlocked, but the credential email could NOT be sent to {user_email}.")
    else:
        messages.error(request, msg)

    next_page = request.GET.get('next')
    if next_page not in ('user_unlock', 'manager_dashboard'):
        next_page = 'manager_dashboard'
    return redirect(next_page)


# 11b. USER UNLOCK PAGE (menu: User Unlock)
#      Manageuser-style flow. The page submits the mobile number (POST field
#      'mobileno', or the <str:mobileno> path arg, or ?mobileno=), then the
#      view delegates to the custom API() class:
#          GetUserByMobileNo / GetUserStatus
#          GetUserStatusByStatusName / UpdateUserStatus
#      The status-update form (btnupdateuser) is handled below.
@permission_required_sp('user_unlock')
def user_unlock(request, mobileno=''):
    from datetime import datetime

    curdatetime = datetime.now().strftime('%y-%b-%d')
    errormsg = ''
    mobile = (mobileno or request.POST.get('mobileno') or request.GET.get('mobileno') or '').strip()
    infos = []
    userstatuslists = []

    try:
        from login.api import API
        api = API()

        infos = _normalize_user_infos(api.GetUserByMobileNo(mobile))
        userstatuslists = _normalize_user_statuses(api.GetUserStatus())

        if request.method == 'POST' and 'btnupdateuser' in request.POST:
            lockCount = request.POST.get('txtlockCount')
            statusname = request.POST.get('sltappUserStatus')
            appuserstatusid = api.GetUserStatusByStatusName(statusname)
            updatedBy = request.session.get('JB_BankID') or request.session.get('JB_UserID')
            updatedDate = curdatetime
            appuserinfoid = request.POST.get('txtappuserinfoid')
            remarks = request.POST.get('txtremarks')

            resultforpwdlock = api.UpdateUserStatus(appuserinfoid, appuserstatusid, updatedBy, remarks)

            if resultforpwdlock:
                insertuserlog(request, appuserinfoid, "User Status Change")
                errormsg = 'Update Done Successfully.'
            else:
                errormsg = 'Update Not Done.'

            return render(request, 'login/user_unlock.html', {
                'errormsg': errormsg, 'infos': infos, 'mobileno': mobile,
                'userstatuslists': userstatuslists,
                'actor_role': request.session.get('JB_RoleName', ''),
            })
    except Exception as exc:
        errormsg = str(exc)

    return render(request, 'login/user_unlock.html', {
        'infos': infos, 'errormsg': errormsg, 'userstatuslists': userstatuslists,
        'mobileno': mobile,
        'actor_role': request.session.get('JB_RoleName', ''),
    })


def _normalize_user_infos(rows):
    """Map whatever keys your API returns to the canonical keys used by
    templates/login/user_unlock.html. Items that are not dicts are skipped."""
    aliases = {
        'appuserinfoid': ('appuserinfoid', 'userinfoid', 'id'),
        'userid': ('userid', 'user_id', 'username', 'loginid'),
        'fullname': ('fullname', 'name'),
        'mobile': ('mobile', 'mobileno', 'mobile_no'),
        'email': ('email',),
        'status': ('status', 'statusname', 'userstatus'),
        'role_name': ('role_name', 'rolename'),
        'failed_attempts': ('failed_attempts', 'lockcount', 'lock_count'),
    }
    normalized = []
    for item in rows or []:
        if not isinstance(item, dict):
            continue
        row = {'appuserinfoid': None, 'userid': None, 'fullname': None,
               'mobile': None, 'email': None, 'status': None,
               'role_name': None, 'failed_attempts': None}
        for canonical, keys in aliases.items():
            for key in keys:
                if item.get(key) is not None:
                    row[canonical] = item[key]
                    break
        normalized.append(row)
    return normalized


def _normalize_user_statuses(rows):
    """Return a list of {'statusname': ...} dicts for the dropdown options."""
    normalized = []
    for item in rows or []:
        if isinstance(item, dict):
            name = item.get('statusname') or item.get('status') or item.get('name')
        else:
            name = item
        if name is not None:
            normalized.append({'statusname': name})
    return normalized


# 11c. ASSIGN MENU PAGE (menu: Assign Menu - Superadmin & Manager only)
@permission_required_sp('assign_menu')
def assign_menu(request):
    actor_user_id = get_session_user(request)
    is_ajax = request.headers.get('X-Requested-With') == 'XMLHttpRequest'

    if request.method == 'POST':
        target_user_id = (request.POST.get('user_id') or '').strip()
        action = request.POST.get('action')

        menu_id = None
        if action in ('assign', 'remove'):
            raw_menu = request.POST.get('menu_id')
            try:
                menu_id = int(raw_menu)
            except (TypeError, ValueError):
                menu_id = None

        is_support_toggle = action in ('set_support', 'unset_support')

        valid = target_user_id and ((action in ('assign', 'remove') and menu_id is not None) or is_support_toggle)
        if not valid:
            msg = "Invalid request."
            if is_ajax:
                return JsonResponse({'success': False, 'message': msg})
            messages.error(request, msg)
            return redirect('assign_menu')

        with connection.cursor() as django_cursor:
            cursor = django_cursor.connection.cursor()

            success = cursor.var(int)
            msg = cursor.var(str)

            if is_support_toggle:
                enable = 1 if action == 'set_support' else 0
                cursor.callproc('SP_ASSIGN_BANK_SUPPORT_ROLE', [
                    actor_user_id, target_user_id, enable, success, msg
                ])
            else:
                enable = 1 if action == 'assign' else 0
                cursor.callproc('SP_SET_USER_MENU_ACCESS', [
                    actor_user_id, target_user_id, menu_id, enable, success, msg
                ])

            ok = success.getvalue() == 1
            text = msg.getvalue()

            if is_ajax:
                return JsonResponse({'success': ok, 'message': text})

            if ok:
                messages.success(request, text)
            else:
                messages.error(request, text)

        return redirect('assign_menu')

    assignable_menus = []
    users = []
    with connection.cursor() as django_cursor:
        cursor = django_cursor.connection.cursor()

        menus_cur = cursor.connection.cursor()
        cursor.callproc('SP_GET_ASSIGNABLE_MENUS', [actor_user_id, menus_cur])
        for row in menus_cur:
            assignable_menus.append({
                'menu_id': row[0],
                'title': row[1],
                'url_name': row[2],
                'icon': row[3],
            })
        menus_cur.close()

        users_cur = cursor.connection.cursor()
        cursor.callproc('SP_GET_MENU_ASSIGN_USERS', [actor_user_id, users_cur])
        for row in users_cur:
            menu_ids_str = row[7] or ''
            menu_titles_str = row[8] or ''
            ids = [x for x in menu_ids_str.split(',') if x]
            titles = [x for x in menu_titles_str.split('|') if x]
            assigned = []
            for mid, title in zip(ids, titles):
                try:
                    assigned.append({'menu_id': int(mid), 'title': title})
                except ValueError:
                    continue
            users.append({
                'user_id': row[0],
                'user_detail_id': row[1],
                'fullname': row[2],
                'email': row[3],
                'status': row[4],
                'role_name': row[5],
                'role_id': row[6],
                'assigned_menus': assigned,
            })
        users_cur.close()

    actor_role = request.session.get('JB_RoleName', '')

    return render(request, 'login/assign_menu.html', {
        'assignable_menus': assignable_menus,
        'users': users,
        'actor_role': actor_role,
    })


# 11d. LEGACY REDIRECT (old 'assign_role' URL kept alive for stale sessions)
def assign_role_legacy(request):
    return redirect('assign_menu')


# 12. SUPERADMIN VIEW: CREATE MANAGER ACCOUNT
@permission_required_sp('create_manager')
def create_manager(request):
    if request.method == 'POST':
        superadmin_id = get_session_user(request)
        fullname = (request.POST.get('fullname') or '').strip()
        mobile = (request.POST.get('mobile') or '').strip()
        email = (request.POST.get('email') or '').strip()
        nid = (request.POST.get('nid') or '').strip()

        if not fullname:
            messages.error(request, "Please enter the manager's full name.")
            return render(request, 'login/create_manager.html')
        if not mobile or not email or not nid:
            messages.error(request, "Mobile, email and NID are all required.")
            return render(request, 'login/create_manager.html')

        try:
            file_path = save_upload(request, 'managers', 'photo',
                                     ('.jpg', '.jpeg', '.png'), 5 * 1024 * 1024)
        except ValueError as exc:
            messages.error(request, str(exc))
            return render(request, 'login/create_manager.html')

        if not file_path:
            messages.error(request, "Please upload the manager's photo (JPG / PNG only).")
            return render(request, 'login/create_manager.html')

        temp_pwd = generate_random_password()
        hashed_pwd = make_password(temp_pwd)

        with connection.cursor() as django_cursor:
            cursor = django_cursor.connection.cursor()

            gen_user_id = cursor.var(str)
            success = cursor.var(int)
            msg = cursor.var(str)

            cursor.callproc('SP_CREATE_MANAGER_BY_SUPERADMIN', [
                superadmin_id, fullname, mobile, email, nid,
                file_path, hashed_pwd, gen_user_id, success, msg
            ])

            if success.getvalue() == 1:
                email_sent = dispatch_email(
                    "Manager Account Created - Access Credentials",
                    f"Your manager account has been created.\n"
                    f"User ID: {gen_user_id.getvalue()}\n"
                    f"Temporary Password: {temp_pwd}\n\n"
                    "Please log in and change your password on first sign-in.",
                    email,
                )
                if email_sent:
                    messages.success(request, f"Manager created. User ID: {gen_user_id.getvalue()} and credentials emailed to {email}.")
                else:
                    messages.error(request, f"Manager created with User ID {gen_user_id.getvalue()}, but the credential email could NOT be sent to {email}.")
            else:
                messages.error(request, msg.getvalue())

        return redirect('create_manager')

    return render(request, 'login/create_manager.html')

