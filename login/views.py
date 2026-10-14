import logging
import re
import secrets
import string
from functools import wraps
from django.shortcuts import render, redirect
from django.contrib import messages
from django.http import JsonResponse
from django.contrib.auth.hashers import make_password, check_password

from login.api import API, MAX_LOGIN_ATTEMPTS, EJANATA_STATEMENT_NOT_FOUND_MESSAGE, HIDDEN_SIDEBAR_MENUS
from login.decorators import permission_required_sp
from login.utils import get_session_user, save_upload, dispatch_email, insertuserlog
from login.clssecurity import clsSecurity
from django.conf import settings

logger = logging.getLogger(__name__)


# ------------------------------------------------------------------
# Oracle connection helper (same style as API class)
# ------------------------------------------------------------------
def get_oracle_cursor():
    """Return (connection, cursor) using the same method as the API class."""
    conn = API._get_connection()
    cursor = conn.cursor()
    return conn, cursor


def generate_random_password(length=10):
    chars = string.ascii_letters + string.digits + "!@#$%^&*"
    return ''.join(secrets.choice(chars) for _ in range(length))


def _load_user_menus(cursor, user_detail_id):
    """Load user menus using an existing Oracle cursor."""
    menu_cursor = cursor.connection.cursor()
    cursor.callproc('SP_GET_USER_MENUS', [str(user_detail_id), menu_cursor])

    permitted_menus = []
    for row in menu_cursor:
        url_name = row[2]
        permitted_menus.append({
            'id': row[0],
            'title': row[1],
            'url_name': url_name,
            'parent_id': row[3],
            'icon': row[4],
            'hidden': url_name in HIDDEN_SIDEBAR_MENUS,
        })
    menu_cursor.close()
    return permitted_menus


def _notify_password_changed(request):
    email = request.session.get('JB_Email')
    if not email:
        return False
    return dispatch_email(
        request,
        "Password Changed",
        email,
        fullname=request.session.get('JB_FullName', ''),
        userid=request.session.get('JB_UserID', ''),
        message=(
            "Your password has been changed successfully.\n\n"
            "If you did not perform this change, contact your administrator immediately."
        ),
    )


def _register_failed_login(user_detail_id):
    if not user_detail_id:
        return 0
    try:
        return int(API().RegisterFailedLoginAttempt(user_detail_id, MAX_LOGIN_ATTEMPTS) or 0)
    except Exception:
        logger.exception("Could not record the failed login for %r", user_detail_id)
        return 0


def _reset_failed_login(user_detail_id):
    if not user_detail_id:
        return False
    try:
        return bool(API().ResetFailedLoginAttempt(user_detail_id))
    except Exception:
        logger.exception("Could not clear the failed-login counter for %r", user_detail_id)
        return False


def dashboard(request):
    """Landing page - identical for every role (Superadmin, Manager, User).

    Each role reaches its own management screens (Admin Dashboard / Manager
    Dashboard) from the sidebar menu instead of being redirected here.
    """
    if not get_session_user(request):
        return redirect('login_page')

    return render(request, 'login/dashboard.html')


def logout_view(request):
    request.session.flush()
    return redirect('login_page')


def login_view(request):
    if request.method == 'POST':
        user_id = (request.POST.get('user_id') or '').strip()
        password = request.POST.get('password') or ''

        conn = None
        try:
            conn, cursor = get_oracle_cursor()

            user_detail_id = cursor.var(int)
            hashed_pwd = cursor.var(str)
            is_first_login = cursor.var(int)
            status = cursor.var(str)
            failed_attempts = cursor.var(int)
            success = cursor.var(int)
            msg = cursor.var(str)

            cursor.callproc('SP_AUTHENTICATE_USER', [
                user_id, user_detail_id, hashed_pwd, is_first_login,
                status, failed_attempts, success, msg
            ])

            if success.getvalue() == 1:
                stored_hashed = hashed_pwd.getvalue()
                account_status = (status.getvalue() or 'Enabled').strip().title()
                previous_attempts = int(failed_attempts.getvalue() or 0)
                detail_id = user_detail_id.getvalue()

                if not stored_hashed or '$' not in stored_hashed:
                    messages.error(
                        request,
                        "The password stored for this account is invalid or incomplete. "
                        "Please use 'Forgot password?' to reset it."
                    )
                elif account_status != 'Enabled':
                    messages.error(
                        request,
                        "Your account is currently %s. It is disabled automatically after "
                        "%s wrong passwords. Please contact your Manager or Superadmin to "
                        "re-enable it." % (account_status, MAX_LOGIN_ATTEMPTS)
                    )
                elif check_password(password, stored_hashed):
                    request.session['JB_UserDetailID'] = detail_id
                    request.session['JB_UserID'] = user_id
                    request.session['JB_Status'] = 'Enabled'

                    _reset_failed_login(detail_id)
                    request.session['USER_MENUS'] = _load_user_menus(cursor, detail_id)

                    try:
                        user_name = cursor.var(str)
                        email = cursor.var(str)
                        image_path = cursor.var(str)
                        role_name = cursor.var(str)
                        success2 = cursor.var(int)

                        cursor.callproc('SP_GET_USER_DETAILS', [
                            detail_id, user_name, email,
                            image_path, role_name, success2
                        ])
                        request.session['JB_FullName'] = user_name.getvalue()
                        request.session['JB_ImagePath'] = image_path.getvalue()
                        request.session['JB_RoleName'] = (role_name.getvalue() or '').strip()
                        request.session['JB_Email'] = email.getvalue()
                    except Exception:
                        logger.exception("SP_GET_USER_DETAILS failed for %r", detail_id)
                        request.session['JB_FullName'] = user_id

                    if is_first_login.getvalue() == 1:
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
                    attempts = _register_failed_login(detail_id)
                    if attempts >= MAX_LOGIN_ATTEMPTS:
                        messages.error(
                            request,
                            "Invalid User ID or Password. Your account has been DISABLED after "
                            "%s wrong attempts. Please contact your Manager or Superadmin to "
                            "re-enable it." % MAX_LOGIN_ATTEMPTS
                        )
                    else:
                        messages.error(
                            request,
                            "Invalid User ID or Password. %s attempt(s) left before your account "
                            "is disabled." % (MAX_LOGIN_ATTEMPTS - attempts)
                        )
            else:
                reason = (msg.getvalue() or '').strip()
                if not reason or 'ORA-' in reason:
                    reason = "Invalid User ID or Password."
                messages.error(request, reason)

        except Exception:
            logger.exception("Login failed for user %r", user_id)
            messages.error(request, "Unable to process login right now. Please try again.")
        finally:
            if conn:
                try:
                    conn.close()
                except Exception:
                    pass

    return render(request, 'login/login_register.html')


def register_user(request):
    if request.method == 'POST':
        fullname = (request.POST.get('fullname') or '').strip()
        mobile = (request.POST.get('mobile') or '').strip()
        email = (request.POST.get('email') or '').strip().lower()
        nid = (request.POST.get('nid') or '').strip()
        office_id = (request.POST.get('officeid') or '').strip()

        validation_error = _validate_contact(fullname, mobile, email, nid)
        if validation_error:
            messages.error(request, validation_error)
            return redirect('login_page')

        office_id_error = _validate_office_id(office_id)
        if office_id_error:
            messages.error(request, office_id_error)
            return redirect('login_page')

        try:
            file_path = save_upload(request, 'attachments', 'attachment',
                                     ('.jpg', '.jpeg', '.png'), 3 * 1024 * 1024)
        except ValueError as exc:
            messages.error(request, str(exc))
            return redirect('login_page')

        conn = None
        try:
            conn, cursor = get_oracle_cursor()
            success = cursor.var(int)
            msg = cursor.var(str)

            cursor.callproc('SP_SUBMIT_REGISTRATION', [
                fullname, mobile, email, nid, office_id, file_path, success, msg
            ])

            if success.getvalue() == 1:
                conn.commit()                       # ← THIS WAS MISSING
                messages.success(request, msg.getvalue())
            else:
                messages.error(request, msg.getvalue())

        except Exception:
            logger.exception("Registration failed")
            messages.error(request, "Unable to submit registration right now.")
            if conn:
                try:
                    conn.rollback()
                except Exception:
                    pass
        finally:
            if conn:
                try:
                    conn.close()
                except Exception:
                    pass

    return redirect('login_page')


@permission_required_sp('pending_registration')
def pending_registration(request):
    pending_users = []
    conn = None
    try:
        conn, cursor = get_oracle_cursor()
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
                'office_id': row[6] if len(row) > 6 else None,
            })
        reg_cursor.close()
    except Exception:
        logger.exception("Failed to load pending registrations")
        messages.error(request, "Unable to load pending registrations.")
    finally:
        if conn:
            try:
                conn.close()
            except Exception:
                pass

    return render(request, 'login/pending_registration.html', {'pending_users': pending_users})


@permission_required_sp('audit_trail')
def audit_trail(request):
    audit_logs = []
    conn = None
    try:
        conn, cursor = get_oracle_cursor()
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
    except Exception:
        logger.exception("Failed to load audit logs")
        messages.error(request, "Unable to load audit logs.")
    finally:
        if conn:
            try:
                conn.close()
            except Exception:
                pass

    return render(request, 'login/audit_trail.html', {'audit_logs': audit_logs})


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
        conn = None
        try:
            conn, cursor = get_oracle_cursor()
            success = cursor.var(int)
            msg = cursor.var(str)

            cursor.callproc('SP_CHANGE_PASSWORD', [user_detail_id, hashed_pwd, success, msg])

            if success.getvalue() == 1:
                _notify_password_changed(request)
                request.session.pop('FORCE_PW_CHANGE', None)
                request.session['USER_MENUS'] = _load_user_menus(cursor, user_detail_id)

                messages.success(
                    request,
                    "Your password has been changed successfully. "
                    "You now have access to your menu permissions."
                )
                return redirect('dashboard')
            else:
                messages.error(request, msg.getvalue())
        except Exception:
            logger.exception("Force password change failed")
            messages.error(request, "Unable to change password right now.")
        finally:
            if conn:
                try:
                    conn.close()
                except Exception:
                    pass

    return render(request, 'login/force_change_password.html')


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
        conn = None
        try:
            conn, cursor = get_oracle_cursor()
            success = cursor.var(int)
            msg = cursor.var(str)

            cursor.callproc('SP_CHANGE_USER_PASSWORD', [user_detail_id, '', hashed_pwd, success, msg])

            if success.getvalue() == 1:
                _notify_password_changed(request)
                messages.success(request, "Password updated successfully. A confirmation has been sent to your registered email.")
                return redirect('dashboard')
            else:
                messages.error(request, msg.getvalue())
        except Exception:
            logger.exception("Change password failed")
            messages.error(request, "Unable to change password right now.")
        finally:
            if conn:
                try:
                    conn.close()
                except Exception:
                    pass

    return render(request, 'login/change_password.html')


def forget_password(request):
    if request.method == 'POST':
        user_id = (request.POST.get('user_id') or '').strip()
        email = (request.POST.get('email') or '').strip().lower()

        if not user_id or not email:
            messages.error(request, "Please enter both your User ID and registered email address.")
            return render(request, 'login/forget_password.html')

        try:
            account = API().GetUserByUserIDAndEmail(user_id, email)
        except Exception as exc:
            logger.error("Forgot-password lookup failed for %r: %s", user_id, exc)
            messages.error(request, "Unable to verify your details right now. Please try again in a moment.")
            return render(request, 'login/forget_password.html')

        if not account:
            messages.error(request, "No matching user found. The User ID and email address do not belong to the same account.")
            return render(request, 'login/forget_password.html')

        temp_pwd = generate_random_password()
        hashed_pwd = make_password(temp_pwd)

        email_sent = dispatch_email(
            request,
            "Password Reset Request",
            email,
            userid=user_id,
            temp_password=temp_pwd,
            message=(
                "Your password has been reset successfully.\n\n"
                "If you did not request this reset, contact your administrator."
            ),
        )
        if not email_sent:
            messages.error(request, "Unable to send the temporary password email. Please try again in a moment or contact your administrator.")
            return render(request, 'login/forget_password.html')

        conn = None
        try:
            conn, cursor = get_oracle_cursor()
            reset_user_detail_id = cursor.var(int)
            success = cursor.var(int)
            msg = cursor.var(str)

            cursor.callproc('SP_FORGOT_PASSWORD_RESET', [
                user_id, email, hashed_pwd, reset_user_detail_id, success, msg
            ])

            if success.getvalue() == 1:
                messages.success(request, "Email sent successfully. A temporary password has been sent to your registered email address.")
            else:
                messages.error(request, msg.getvalue())
        except Exception:
            logger.exception("Forgot password reset failed")
            messages.error(request, "Unable to reset password right now.")
        finally:
            if conn:
                try:
                    conn.close()
                except Exception:
                    pass

    return render(request, 'login/forget_password.html')


@permission_required_sp('manager_dashboard')
def manager_dashboard(request):
    pending_users = []
    locked_users = []
    active_users = []

    conn = None
    try:
        conn, cursor = get_oracle_cursor()

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
                'office_id': row[6] if len(row) > 6 else None,
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
    except Exception:
        logger.exception("Failed to load manager dashboard data")
        messages.error(request, "Unable to load dashboard data.")
    finally:
        if conn:
            try:
                conn.close()
            except Exception:
                pass

    return render(request, 'login/manager_dashboard.html', {
        'pending_users': pending_users,
        'locked_users': locked_users,
        'active_users': active_users,
    })


@permission_required_sp('approve_user')
def approve_user(request, reg_id):
    manager_user_id = get_session_user(request)
    temp_pwd = generate_random_password()
    hashed_pwd = make_password(temp_pwd)

    conn = None
    try:
        conn, cursor = get_oracle_cursor()
        gen_user_id = cursor.var(str)
        user_email = cursor.var(str)
        success = cursor.var(int)
        msg = cursor.var(str)

        cursor.callproc('SP_APPROVE_REGISTRATION', [
            reg_id, hashed_pwd, manager_user_id, gen_user_id, user_email, success, msg
        ])

        if success.getvalue() == 1:
            email_sent = dispatch_email(
                request,
                "Account Approved - Access Credentials",
                user_email.getvalue(),
                userid=gen_user_id.getvalue(),
                temp_password=temp_pwd,
                message="Your registration has been approved.",
            )
            if email_sent:
                messages.success(request, f"User Approved by Manager. User ID: {gen_user_id.getvalue()} and credentials emailed.")
            else:
                messages.error(request, f"User Approved with User ID {gen_user_id.getvalue()}, but the credential email could NOT be sent to {user_email.getvalue()}.")
        else:
            messages.error(request, msg.getvalue())
    except Exception:
        logger.exception("Approve user failed")
        messages.error(request, "Unable to approve user right now.")
    finally:
        if conn:
            try:
                conn.close()
            except Exception:
                pass

    next_page = 'manager_dashboard'
    if (request.session.get('JB_RoleName') or '').strip().upper() == 'SUPERADMIN':
        next_page = 'admin_dashboard'
    return redirect(next_page)


@permission_required_sp('unlock_user')
def unlock_user(request, user_id):
    temp_pwd = generate_random_password()
    hashed_pwd = make_password(temp_pwd)

    try:
        result = API().UnlockUserByBankID(user_id, hashed_pwd) or {}
        success = result.get('success')
        user_email = result.get('user_email')
        msg = result.get('msg')
    except Exception:
        logger.exception("UnlockUserByBankID failed for %r", user_id)
        success, user_email, msg = (
            0, None,
            "The account could not be unlocked right now. Please try again in a few minutes.",
        )

    if success:
        email_sent = dispatch_email(
            request,
            "Account Unlocked - New Temporary Credentials",
            user_email,
            userid=user_id,
            temp_password=temp_pwd,
            message="Your account has been unlocked by manager.",
        )
        if email_sent:
            messages.success(request, f"Account {user_id} unlocked and credentials dispatched.")
        else:
            messages.error(request, f"Account {user_id} unlocked, but the credential email could NOT be sent to {user_email}.")
    else:
        messages.error(request, msg)

    next_page = request.GET.get('next')
    if next_page not in ('disable_enable', 'manageuser', 'user_unlock', 'manager_dashboard'):
        next_page = 'manager_dashboard'
    return redirect(next_page)


# ------------------------------------------------------------------
# Validation helpers (unchanged)
# ------------------------------------------------------------------
MOBILE_RE = re.compile(r'^01[3-9]\d{8}$')
MOBILE_ERROR = "Mobile number must be exactly 11 digits and start with 01 (e.g. 01712345678)."
EMAIL_RE = re.compile(r'^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')
EMAIL_ERROR = "Please enter a valid email address (e.g. name@example.com)."
NID_RE = re.compile(r'^\d{10}$|^\d{13}$|^\d{17}$')
NID_ERROR = "NID number must be exactly 10, 13 or 17 digits."
OFFICE_ID_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9 \-_/]{0,29}$')
OFFICE_ID_ERROR = ("Office ID Number must be 1 to 30 characters and may contain "
                   "only letters, numbers, spaces, '-', '_' or '/'.")

EJANATA_VERIFY_FAILED_MESSAGE = ("The eJanata application could not be reached "
                                 "right now. Please try again in a few minutes.")


def _is_valid_mobile(mobileno):
    return bool(MOBILE_RE.match(str(mobileno or '').strip()))


def _validate_contact(fullname, mobile, email, nid):
    if not fullname:
        return "Please enter the full name."
    if not mobile or not email or not nid:
        return "Mobile, email and NID are all required."
    if not _is_valid_mobile(mobile):
        return MOBILE_ERROR
    if not EMAIL_RE.match(email):
        return EMAIL_ERROR
    if not NID_RE.match(nid):
        return NID_ERROR
    return None


def _validate_office_id(office_id):
    if not office_id:
        return "Please enter your Office ID Number."
    if not OFFICE_ID_RE.match(office_id):
        return OFFICE_ID_ERROR
    return None


def _has_menu(request, *url_names):
    menus = request.session.get('USER_MENUS') or []
    granted = {
        str(m.get('url_name') or '').strip()
        for m in menus
        if isinstance(m, dict)
    }
    return any(name in granted for name in url_names)


def _ejanata_unlock_permission(view_func):
    @wraps(view_func)
    def _wrapped(request, *args, **kwargs):
        if not get_session_user(request):
            return redirect('login_page')
        if not _has_menu(request, 'user_unlock', 'ejanata_user_unlock'):
            messages.error(
                request,
                "Access Denied: You do not have permission to view this section.",
            )
            return redirect('dashboard')
        return view_func(request, *args, **kwargs)
    return _wrapped


UNLOCK_FAILED_MESSAGE = "The account could not be unlocked. Please try again."


_EJANATA_STATUS_LABELS = {
    '1': ('Enabled', 'good'),
    '2': ('Disabled', 'danger'),
    '3': ('Locked', 'danger'),
    '4': ('Reset', 'danger'),
    '5': ('iPhone Inactive', 'danger'),
    '6': ('Android Inactive', 'danger'),
    '7': ('Registration Pending', 'danger'),
    '9': ('Wrong', 'danger'),
}

_EJANATA_UNLOCK_FROM_STATUS = '3'    
_EJANATA_DISABLE_FROM_STATUS = '1'   

EJANATA_STATUS_ENABLED = '1'
EJANATA_STATUS_DISABLED = '2'

EJANATA_BRANCH_CONTACT_TAIL = 'Please contact to nearest Branch'

EJANATA_UNLOCK_REMARKS = 'Unlocked by JB Call Center'
EJANATA_DISABLE_REMARKS = 'Disabled by JB Call Center'


_EJANATA_ACTIONS = {
    'unlock': {
        'button': 'Unlock User',
        'remarks': EJANATA_UNLOCK_REMARKS,
    },
    'disable': {
        'button': 'Disable User',
        'remarks': EJANATA_DISABLE_REMARKS,
    },
}


def _ejanata_action_refusal(statusview, appuserid):
    if statusview['allowed'] and not appuserid:
        return ('The eJanata application did not return an App User ID for this '
                'account. %s' % EJANATA_BRANCH_CONTACT_TAIL)
    return statusview['message']


def _ejanata_apply_status_change(request, api, action, mobileno):

    action_conf = _EJANATA_ACTIONS.get(action)
    if action_conf is None:
        logger.error("Unknown eJanata status action %r", action)
        return False, "The request could not be completed.", ''

    user, error = _ejanata_verify_user(request, api, mobileno)
    if error or not user:
        return False, error or (
            "This mobile number could not be verified against the eJanata "
            "application. Please check the number and try again."
        ), ''

    appuserid = _ejanata_app_user_id(user)
    if not appuserid:
        return False, ("The eJanata application did not return an App User ID "
                       "for this account, so it cannot be %s. Please contact "
                       "to nearest Branch." % action_conf['button']), ''

    statusview = _ejanata_status_view(user, action)
    if not statusview['allowed']:
        logger.info(
            "eJanata %s refused for App User ID %r (mobile %r): status=%r",
            action, appuserid, mobileno, statusview['id'],
        )
        return False, statusview['message'], appuserid

    ok, message = _ejanata_update_user_status(
        request, api, appuserid, statusview['target'], action_conf['remarks'],
    )
    return ok, message, appuserid


def _ejanata_user_unlock_impl(request, mobileno=''):
    api = API()

    mobileno = (mobileno or request.POST.get('mobileno')
                or request.GET.get('mobileno') or '').strip()
    errormsg = ''
    unlocked = None
    ejanatauser = None
    ejanataerr = ''
    searched = False

    mobile_valid = _is_valid_mobile(mobileno)

    if not mobileno:
        if request.method == 'POST':
            errormsg = "Please enter the mobile number of the account to unlock."
    elif not mobile_valid:
        errormsg = MOBILE_ERROR
    elif request.method == 'POST' and request.POST.get('btnunlockuser'):
        ok, msg, appuserid = _ejanata_apply_status_change(
            request, api, action='unlock', mobileno=mobileno,
        )

        if ok:
            unlocked = {'msg': msg}
            insertuserlog(
                request, get_session_user(request),
                "eJanata User Unlock by App User ID %s (Mobile %s)"
                % (appuserid, mobileno),
            )
        else:
            errormsg = msg

        ejanatauser, ejanataerr = _ejanata_verify_user(request, api, mobileno)
        searched = True

    elif request.method == 'POST' and (request.POST.get('btnfetchuser')
                                        or request.POST.get('btnsearch')):
        searched = True
        ejanatauser, ejanataerr = _ejanata_verify_user(request, api, mobileno)

    statusview = _ejanata_status_view(ejanatauser, 'unlock')
    appuserid = _ejanata_app_user_id(ejanatauser)

    return render(request, 'login/ejanata_user_unlock.html', {
        'mobileno': mobileno,
        'appuserinfoid': appuserid,
        'appusername': _ejanata_app_username(ejanatauser),
        'accountno': _ejanata_account_no(ejanatauser),
        'has_acc_statement': _has_menu(request, 'acc_statement'),
        'errormsg': errormsg,
        'searched': searched,
        'ejanatauser': ejanatauser,
        'ejanataerr': ejanataerr,
        'unlocked': unlocked,
        'statusview': statusview,
        'action_message': _ejanata_action_refusal(statusview, appuserid),
        'unlock_allowed': (bool(ejanatauser) and statusview['allowed']
                           and bool(appuserid)),
        'actor_role': request.session.get('JB_RoleName', ''),
    })


@_ejanata_unlock_permission
def user_unlock(request, mobileno=''):
    return _ejanata_user_unlock_impl(request, mobileno)


def _ejanata_request_args(mobileno):
    try:
        solutioncode = clsSecurity.decodestr(settings.EJANATASOLUTIONCODE).strip()
    except Exception:
        logger.exception("Could not read EJANATASOLUTIONCODE")
        return None, ("eJanata verification is not available right now. "
                      "Please try again in a few minutes.")

    if not solutioncode:
        logger.error("EJANATASOLUTIONCODE is empty on this server.")
        return None, ("eJanata verification is not available: "
                      "EJANATASOLUTIONCODE is not configured on this server.")

    return (str(mobileno).strip(), solutioncode, '3'), ''


def _ejanata_update_solution():
    try:
        solutioninfoid = clsSecurity.decodestr(
            settings.EJANATA_UPDATE_USER_SOLUTIONINFOID).strip()
        solutioncode = clsSecurity.decodestr(
            settings.EJANATA_UPDATE_USER_SOLUTIONCODE).strip()
    except Exception:
        logger.exception("Could not read the eJanata update solution settings")
        return None, ("The eJanata application could not be reached right now. "
                      "Please try again in a few minutes.")

    if not solutioninfoid or not solutioncode:
        logger.error(
            "EJANATA_UPDATE_USER_SOLUTIONINFOID / _SOLUTIONCODE is empty on "
            "this server."
        )
        return None, ("The eJanata application could not be reached: its "
                      "solution settings are not configured on this server.")

    return (solutioninfoid, solutioncode), ''


class _EjanataUser:

    def __init__(self, source):
        data = {}
        if isinstance(source, dict):
            data = source
        elif source is not None:
            try:
                data = vars(source)
            except TypeError:
                data = {k: getattr(source, k) for k in dir(source)
                        if not k.startswith('_')}
        self._data = {}
        for key, value in data.items():
            if key is None:
                continue
            self._data[str(key)] = value
            self._data[str(key).lower()] = value

    def __getattr__(self, name):
        if name.startswith('_'):
            raise AttributeError(name)
        if name in self._data:
            return self._data[name]
        lower = name.lower()
        if lower in self._data:
            return self._data[lower]
        return None

    def get(self, name, default=None):
        val = getattr(self, name, None)
        return default if val is None else val


def _ejanata_unwrap_record(payload):
    if payload is None or payload == '' or payload == {}:
        return None

    if isinstance(payload, list):
        if not payload:
            return None
        return _ejanata_unwrap_record(payload[0])

    if isinstance(payload, dict):
        for nest_key in (
            'data', 'Data', 'result', 'Result',
            'appuserinfo', 'Appuserinfo', 'AppUserInfo',
            'user', 'User', 'appuser', 'Appuser',
        ):
            if nest_key in payload and payload[nest_key]:
                return _ejanata_unwrap_record(payload[nest_key])
        return payload

    return payload


def _ejanata_extract_user(response):
    if response is None:
        return None

    candidates = []
    for attr in ('data', 'raw', 'Data', 'Raw', 'result', 'Result'):
        val = getattr(response, attr, None)
        if val is not None and val != '' and val != {}:
            candidates.append(val)

    if not candidates and isinstance(response, dict):
        candidates.append(response)

    for payload in candidates:
        record = _ejanata_unwrap_record(payload)
        if record is not None:
            return _EjanataUser(record)

    return None


def _ejanata_response_code(response):
    if response is None:
        return ''
    for attr in ('ResponseCode', 'responsecode', 'response_code', 'Code', 'code'):
        val = getattr(response, attr, None)
        if val is not None and str(val).strip() != '':
            return str(val).strip()
    if isinstance(response, dict):
        for key in ('ResponseCode', 'responsecode', 'response_code', 'Code', 'code'):
            if key in response and response[key] is not None:
                return str(response[key]).strip()
    return ''


def _ejanata_response_message(response):
    if response is None:
        return ''
    for attr in ('Message', 'message', 'msg', 'Msg'):
        val = getattr(response, attr, None)
        if val is not None and str(val).strip() != '':
            return str(val).strip()
    if isinstance(response, dict):
        for key in ('Message', 'message', 'msg', 'Msg'):
            if key in response and response[key]:
                return str(response[key]).strip()
    return ''


def _ejanata_verify_user(request, api, mobileno):
    args, error = _ejanata_request_args(mobileno)
    if error:
        return None, error

    mobilenumber, solutioncode, confirmationtypeid = args

    try:
        response = api.GeteJanataUserByMobileNo(
            request, mobilenumber, solutioncode, confirmationtypeid,
        )
    except Exception:
        logger.exception("GeteJanataUserByMobileNo failed for %r", mobileno)
        return None, EJANATA_VERIFY_FAILED_MESSAGE

    if response is None:
        logger.error("GeteJanataUserByMobileNo returned no response for %r", mobileno)
        return None, EJANATA_VERIFY_FAILED_MESSAGE

    code = _ejanata_response_code(response)
    if code and code not in ('200', '210'):
        msg = _ejanata_response_message(response)
        logger.warning(
            "eJanata user search for %r failed: code=%r message=%r raw=%r",
            mobileno, code, msg, getattr(response, 'raw', None),
        )
        return None, msg or (
            "This mobile number could not be verified against the eJanata "
            "application. Please check the number and try again."
        )

    user = _ejanata_extract_user(response)
    if not user:
        logger.warning(
            "eJanata user search for %r returned no customer data "
            "(code=%r data=%r raw=%r)",
            mobileno, code,
            getattr(response, 'data', None),
            getattr(response, 'raw', None),
        )
        return None, ("This mobile number could not be verified against the "
                      "eJanata application. Please check the number and try "
                      "again.")

    return user, ''


def _ejanata_status_id(user):
    if not user:
        return ''
    return str(user.get('Appuserstatusid') or '').strip()


def _ejanata_app_user_id(user):
    if not user:
        return ''
    return str(user.get('Appuserinfoid') or '').strip()


def _ejanata_app_username(user):
    """The eJanata login name of the searched customer ('' when absent)."""
    if not user:
        return ''
    return str(user.get('Appusername') or '').strip()


def _ejanata_account_no(user):
    """The CBS account number the statement is fetched for ('' when absent)."""
    if not user:
        return ''
    return str(user.get('Cbsaccountno') or '').strip()


def _ejanata_status_view(user, action):
    statusid = _ejanata_status_id(user)
    label, tone = _EJANATA_STATUS_LABELS.get(
        statusid, (statusid or 'Unknown', 'danger'),
    )

    if action == 'unlock':
        required = _EJANATA_UNLOCK_FROM_STATUS
        target = EJANATA_STATUS_ENABLED
    else:
        required = _EJANATA_DISABLE_FROM_STATUS
        target = EJANATA_STATUS_DISABLED

    allowed = bool(statusid) and statusid == required

    return {
        'id': statusid,
        'label': label,
        'tone': tone,
        'allowed': allowed,
        'target': target,
        'message': '' if allowed else (
            'Current Status: %s, %s' % (label, EJANATA_BRANCH_CONTACT_TAIL)
        ),
    }


_EJANATA_OK_CODES = ('200', '210')


def _ejanata_update_user_status(request, api, appuserinfoid, appuserstatusid,
                                remarks):
    solution, error = _ejanata_update_solution()
    if error:
        return False, error

    appuserid = str(appuserinfoid or '').strip()
    if not appuserid:
        return False, ("This account has no App User ID in the eJanata "
                       "application, so it cannot be updated here.")

    updatedby = str(request.session.get('JB_UserID') or '').strip()

    try:
        response = api.update_app_user_status(
            request,
            appuserinfoid=appuserid,
            appuserstatusid=appuserstatusid,
            remarks=remarks,
            passwordlockcount='0',
            updatedby=updatedby,
            solutioninfoid=solution[0],
            solutioncode=solution[1],
        )
    except Exception:
        logger.exception(
            "update_app_user_status failed for appuserinfoid=%r status=%r",
            appuserid, appuserstatusid,
        )
        return False, EJANATA_VERIFY_FAILED_MESSAGE

    if response is None:
        logger.error(
            "update_app_user_status returned no response for appuserinfoid=%r",
            appuserid,
        )
        return False, EJANATA_VERIFY_FAILED_MESSAGE

    code = _ejanata_response_code(response)
    msg = _ejanata_response_message(response)
    if code in _EJANATA_OK_CODES:
        if appuserstatusid == EJANATA_STATUS_ENABLED:
            return True, msg or "The account was unlocked."
        return True, msg or "The account was disabled."

    logger.warning(
        "eJanata status update for appuserinfoid=%r failed: status=%r code=%r "
        "message=%r", appuserid, appuserstatusid, code, msg,
    )
    return False, msg or "The eJanata account could not be updated."

    logger.warning("eJanata unlock for %r failed: code=%r message=%r",
                   mobileno, code, msg)
    return False, msg or "The eJanata account could not be unlocked."


@_ejanata_unlock_permission
def ejanata_user_unlock(request, mobileno=''):
    return _ejanata_user_unlock_impl(request, mobileno)



SUPERADMIN_ONLY = ('SUPERADMIN',)


def superadmin_required(view_func):
    @wraps(view_func)
    def _wrapped_view(request, *args, **kwargs):
        role = (request.session.get('JB_RoleName') or '').strip().upper()
        if role not in SUPERADMIN_ONLY:
            messages.error(
                request,
                "Access Denied: This section is restricted to SuperAdmin.",
            )
            return redirect('dashboard')
        return view_func(request, *args, **kwargs)

    return _wrapped_view


@permission_required_sp('disable_ejanata_user')
def disable_ejanata_user(request, mobileno=''):
    api = API()

    mobileno = (mobileno or request.POST.get('mobileno')
                or request.GET.get('mobileno') or '').strip()
    errormsg = ''
    disabled = None
    ejanatauser = None
    ejanataerr = ''
    searched = False

    mobile_valid = _is_valid_mobile(mobileno)

    if not mobileno:
        if request.method == 'POST':
            errormsg = "Please enter the mobile number of the account to disable."
    elif not mobile_valid:
        errormsg = MOBILE_ERROR
    elif request.method == 'POST' and request.POST.get('btndisableuser'):
        ok, msg, appuserid = _ejanata_apply_status_change(
            request, api, action='disable', mobileno=mobileno,
        )

        if ok:
            disabled = {'msg': msg}
            insertuserlog(
                request, get_session_user(request),
                "eJanata User Disable by App User ID %s (Mobile %s)"
                % (appuserid, mobileno),
            )
        else:
            errormsg = msg

        ejanatauser, ejanataerr = _ejanata_verify_user(request, api, mobileno)
        searched = True

    elif request.method == 'POST' and (request.POST.get('btnfetchuser')
                                        or request.POST.get('btnsearch')):
        searched = True
        ejanatauser, ejanataerr = _ejanata_verify_user(request, api, mobileno)

    statusview = _ejanata_status_view(ejanatauser, 'disable')
    appuserid = _ejanata_app_user_id(ejanatauser)

    return render(request, 'login/disable_ejanata_user.html', {
        'mobileno': mobileno,
        'appuserinfoid': appuserid,
        'appusername': _ejanata_app_username(ejanatauser),
        'accountno': _ejanata_account_no(ejanatauser),
        'has_acc_statement': _has_menu(request, 'acc_statement'),
        'errormsg': errormsg,
        'searched': searched,
        'ejanatauser': ejanatauser,
        'ejanataerr': ejanataerr,
        'disabled': disabled,
        'statusview': statusview,
        'action_message': _ejanata_action_refusal(statusview, appuserid),
        'disable_allowed': (bool(ejanatauser) and statusview['allowed']
                            and bool(appuserid)),
        'actor_role': request.session.get('JB_RoleName', ''),
    })



_DEBIT_WORDS = ('DEBIT', 'DR', 'D', 'WITHDRAWAL', 'WITHDRAW', 'PAYMENT', 'DEBITED')
_CREDIT_WORDS = ('CREDIT', 'CR', 'C', 'DEPOSIT', 'CREDITED')


def _statement_type(raw):
    words = (str(raw or '').strip().upper()
             .replace('/', ' ').replace('-', ' ').split())
    if not words:
        return ''
    is_debit = any(word in _DEBIT_WORDS for word in words)
    is_credit = any(word in _CREDIT_WORDS for word in words)
    if is_debit and is_credit:
        return ''
    if is_debit:
        return 'Debit'
    if is_credit:
        return 'Credit'
    return ''


def _acc_statement_rows(transactions):
    rows = []
    for item in transactions or []:
        if not isinstance(item, dict):
            continue
        kind = _statement_type(item.get('type'))
        rows.append({
            'txndate': str(item.get('txndate') or '').strip() or '-',
            'amount': str(item.get('amount') or '').strip() or '-',
            'type': kind or str(item.get('type') or '').strip() or '-',
            'description': str(item.get('description') or '').strip() or '-',
            'is_debit': kind == 'Debit',
            'is_credit': kind == 'Credit',
        })
    return rows


def _acc_statement_totals(rows):
    def _sum(is_debit):
        total = 0.0
        for row in rows:
            if row['is_debit'] is not is_debit:
                continue
            try:
                total += float(str(row['amount']).replace(',', '').strip())
            except (TypeError, ValueError):
                continue
        return total

    return {
        'debit': _sum(True),
        'credit': _sum(False),
        'debit_count': sum(1 for r in rows if r['is_debit']),
        'credit_count': sum(1 for r in rows if r['is_credit']),
    }


def _money(value):
    """Format a computed total for the JSON payload (two decimals)."""
    try:
        return '%.2f' % float(value)
    except (TypeError, ValueError):
        return '0.00'


def acc_statement(request):
    """Mini account statement for the user shown in the User Information panel.

    Called by the Account Statement option under that panel's action bar on the
    User Unlock and Disable eJanata User screens. The eJanata identifiers are the
    ones the mobile-number search already returned for the customer and are
    posted hidden from the page, so no account number is ever typed here.

    This is a JSON lookup, not a page: it exists only to feed the table shown on
    that same page, and it is gated by the same Acc Statement menu permission
    that makes the option visible in the first place.
    """
    if not get_session_user(request):
        return JsonResponse(
            {'success': False,
             'message': 'Your session has expired. Please sign in again.'},
            status=401,
        )

    if not _has_menu(request, 'acc_statement'):
        return JsonResponse(
            {'success': False,
             'message': 'Access Denied: You do not have permission to view the '
                        'account statement.'},
            status=403,
        )

    if request.method != 'POST':
        return JsonResponse(
            {'success': False, 'message': 'Invalid request.'}, status=405,
        )

    appuserinfoid = (request.POST.get('appuserinfoid') or '').strip()
    appusername = (request.POST.get('appusername') or '').strip()
    accountno = (request.POST.get('accountno') or '').strip()

    try:
        result = API().GetAccountStatement(
            request, appuserinfoid, appusername, accountno,
        )
    except Exception:
        logger.exception("GetAccountStatement failed for accountno=%r", accountno)
        return JsonResponse({
            'success': False,
            'message': EJANATA_STATEMENT_NOT_FOUND_MESSAGE,
        })

    rows = _acc_statement_rows(result.get('transactions'))
    totals = _acc_statement_totals(rows)
    totals['debit'] = _money(totals['debit'])
    totals['credit'] = _money(totals['credit'])

    return JsonResponse({
        'success': bool(result.get('success')) or bool(rows),
        'message': result.get('message') or '',
        'rows': rows,
        'totals': totals,
    })


@permission_required_sp('disable_enable')
def disable_enable(request, mobileno=''):
    api = API()
    actor_id = get_session_user(request)
    actor_role = request.session.get('JB_RoleName', '')

    mobileno = (mobileno or request.POST.get('mobileno')
                or request.GET.get('mobileno') or '').strip()
    errormsg = ''
    okmsg = ''

    mobileno_valid = _is_valid_mobile(mobileno)
    if mobileno and not mobileno_valid:
        errormsg = MOBILE_ERROR

    try:
        infos = _normalize_user_infos(api.GetUserByMobileNo(mobileno)) if mobileno_valid else []
        userstatuslists = _normalize_user_statuses(api.GetUserStatus())

        if mobileno_valid and request.method == 'POST' and request.POST.get('btnupdateuser'):
            target_id = (request.POST.get('txtappuserinfoid') or '').strip()
            statusname = request.POST.get('sltappUserStatus') or ''
            remarks = (request.POST.get('txtremarks') or '').strip()

            try:
                api.SetUserStatus(actor_id, target_id, statusname, remarks)
            except ValueError as exc:
                errormsg = str(exc)
            except Exception:
                logger.exception("SetUserStatus failed for target %r", target_id)
                errormsg = ("The status could not be changed right now. "
                            "Please try again in a few minutes.")
            else:
                okmsg = "%s is now %s." % (
                    (request.POST.get('txtuserid') or 'The account').strip(),
                    statusname.strip().title(),
                )
                insertuserlog(
                    request, actor_id,
                    "User Status Change -> %s" % statusname.strip().title(),
                )
                infos = _normalize_user_infos(api.GetUserByMobileNo(mobileno))
    except Exception:
        logger.exception("disable_enable failed for %r", mobileno)
        errormsg = ("The user could not be looked up right now. Please try "
                    "again in a few minutes.")
        infos, userstatuslists = [], []

    return render(request, 'login/disable_enable.html', {
        'infos': infos,
        'errormsg': errormsg,
        'okmsg': okmsg,
        'userstatuslists': userstatuslists,
        'mobileno': mobileno,
        'actor_role': actor_role,
    })


def manageuser(request, mobileno=''):
    return redirect('disable_enable')


def _normalize_user_infos(rows):
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
    normalized = []
    for item in rows or []:
        if isinstance(item, dict):
            name = item.get('statusname') or item.get('status') or item.get('name')
        else:
            name = item
        if name is not None:
            normalized.append({'statusname': name})
    return normalized


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

        conn = None
        try:
            conn, cursor = get_oracle_cursor()
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

            if ok:
                conn.commit()

            if is_ajax:
                return JsonResponse({'success': ok, 'message': text})

            if ok:
                messages.success(request, text)
            else:
                messages.error(request, text)

        except Exception:
            logger.exception("assign_menu failed")
            if is_ajax:
                return JsonResponse({'success': False, 'message': 'Unable to process request.'})
            messages.error(request, "Unable to process the request right now.")
        finally:
            if conn:
                try:
                    conn.close()
                except Exception:
                    pass

        return redirect('assign_menu')

    # GET request
    assignable_menus = []
    users = []
    conn = None
    try:
        conn, cursor = get_oracle_cursor()

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
    except Exception:
        logger.exception("Failed to load assign_menu data")
        messages.error(request, "Unable to load menu assignment data.")
    finally:
        if conn:
            try:
                conn.close()
            except Exception:
                pass

    actor_role = request.session.get('JB_RoleName', '')

    return render(request, 'login/assign_menu.html', {
        'assignable_menus': assignable_menus,
        'users': users,
        'actor_role': actor_role,
    })

def assign_role_legacy(request):
    return redirect('assign_menu')


@permission_required_sp('create_manager')
def create_manager(request):
    if request.method == 'POST':
        superadmin_id = get_session_user(request)
        fullname = (request.POST.get('fullname') or '').strip()
        mobile = (request.POST.get('mobile') or '').strip()
        email = (request.POST.get('email') or '').strip().lower()
        nid = (request.POST.get('nid') or '').strip()
        officeid = (request.POST.get('officeid') or '').strip()

        if not fullname:
            messages.error(request, "Please enter the manager's full name.")
            return render(request, 'login/create_manager.html')

        validation_error = _validate_contact(fullname, mobile, email, nid)
        if validation_error:
            messages.error(request, validation_error)
            return render(request, 'login/create_manager.html')

        office_id_error = _validate_office_id(officeid)
        if office_id_error:
            messages.error(request, office_id_error)
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

        conn = None
        try:
            conn, cursor = get_oracle_cursor()

            gen_user_id = cursor.var(str)
            success = cursor.var(int)
            msg = cursor.var(str)

            cursor.callproc('SP_CREATE_MANAGER_BY_SUPERADMIN', [
                superadmin_id, fullname, mobile, email, nid,
                file_path, hashed_pwd, gen_user_id, success, msg
            ])

            if success.getvalue() == 1:
                cursor.execute(
                    "UPDATE USERDETAIL SET OFFICE_ID = :office_id "
                    "WHERE USERID = :userid",
                    {'office_id': officeid, 'userid': gen_user_id.getvalue()},
                )
                conn.commit()
                email_sent = dispatch_email(
                    request,
                    "Manager Account Created - Access Credentials",
                    email,
                    fullname=fullname,
                    userid=gen_user_id.getvalue(),
                    temp_password=temp_pwd,
                    message="Your manager account has been created.",
                )
                if email_sent:
                    messages.success(request, f"Manager created. User ID: {gen_user_id.getvalue()} and credentials emailed to {email}.")
                else:
                    messages.error(request, f"Manager created with User ID {gen_user_id.getvalue()}, but the credential email could NOT be sent to {email}.")
            else:
                messages.error(request, msg.getvalue())
        except Exception:
            logger.exception("Create manager failed")
            messages.error(request, "Unable to create manager right now.")
            if conn:
                try:
                    conn.rollback()
                except Exception:
                    pass
        finally:
            if conn:
                try:
                    conn.close()
                except Exception:
                    pass

        return redirect('create_manager')

    return render(request, 'login/create_manager.html')


# ==================================================================
# ADMIN DASHBOARD (Super Admin only)
#   - Pending registrations to approve
#   - Managers and regular Users (incl. Bank Support) with enable/disable
#   - Make / remove Bank Support role
# ==================================================================
@permission_required_sp('dashboard')
@superadmin_required
def admin_dashboard(request):
    pending_users = []
    managers = []
    users = []
    conn = None
    try:
        conn, cursor = get_oracle_cursor()

        pending_cur = cursor.connection.cursor()
        cursor.callproc('SP_GET_PENDING_REGISTRATIONS', [pending_cur])
        for row in pending_cur:
            pending_users.append({
                'registration_id': row[0],
                'fullname': row[1],
                'mobile': row[2],
                'email': row[3],
                'nid': row[4],
                'attachment_path': row[5],
                'office_id': row[6] if len(row) > 6 else None,
            })
        pending_cur.close()

        mgr_cur = cursor.connection.cursor()
        cursor.callproc('SP_GET_MANAGERS', [mgr_cur])
        for row in mgr_cur:
            managers.append({
                'user_detail_id': row[0],
                'user_id': row[1],
                'fullname': row[2],
                'mobile': row[3],
                'email': row[4],
                'status': row[5],
                'failed_attempts': row[6],
                'image_path': row[7],
                'created_at': row[8],
            })
        mgr_cur.close()

        user_cur = cursor.connection.cursor()
        cursor.callproc('SP_GET_USERS_FOR_ADMIN', [user_cur])
        for row in user_cur:
            users.append({
                'user_detail_id': row[0],
                'user_id': row[1],
                'fullname': row[2],
                'mobile': row[3],
                'email': row[4],
                'role_name': row[5],
                'image_path': row[6],
                'status': row[7],
                'created_at': row[8],
            })
        user_cur.close()
    except Exception:
        logger.exception("Failed to load admin dashboard data")
        messages.error(request, "Unable to load dashboard data.")
    finally:
        if conn:
            try:
                conn.close()
            except Exception:
                pass

    return render(request, 'login/admin_dashboard.html', {
        'pending_users': pending_users,
        'managers': managers,
        'users': users,
    })


# ==================================================================
# Make / remove Bank Support role (Super Admin only)
#   Reuses SP_ASSIGN_BANK_SUPPORT_ROLE which also grants/revokes the
#   ticket menus so a Bank Support user can actually open and answer.
# ==================================================================
@permission_required_sp('dashboard')
@superadmin_required
def set_bank_support(request, user_id, action):
    actor_id = get_session_user(request)
    if not actor_id:
        return redirect('login_page')

    enable = 1 if (action or '').strip().lower() in ('set_support', 'make', 'enable') else 0

    conn = None
    try:
        conn, cursor = get_oracle_cursor()
        success = cursor.var(int)
        msg = cursor.var(str)
        cursor.callproc('SP_ASSIGN_BANK_SUPPORT_ROLE', [
            actor_id, user_id, enable, success, msg
        ])
        ok = success.getvalue() == 1
        text = msg.getvalue()
        if ok:
            conn.commit()
            messages.success(request, text)
        else:
            messages.error(request, text)
    except Exception:
        logger.exception("set_bank_support failed for %r", user_id)
        messages.error(request, "Unable to change the Bank Support role right now.")
    finally:
        if conn:
            try:
                conn.close()
            except Exception:
                pass

    return redirect('admin_dashboard')


# ==================================================================
# Shared enable/disable action used by BOTH dashboards.
# The Oracle procedure SP_SET_USER_STATUS enforces the policy:
#   - Superadmin -> any account (Manager or User)
#   - Manager    -> ONLY a regular 'User'
# ==================================================================
@permission_required_sp('dashboard')
def set_account_status(request, user_id, status):
    actor_id = get_session_user(request)
    if not actor_id:
        return redirect('login_page')

    new_status = (status or '').strip().title()
    if new_status not in ('Enabled', 'Disabled'):
        messages.error(request, "Invalid status request.")
        return redirect('dashboard')

    try:
        target_detail_id = API()._detail_id_of_userid(user_id)
        if not target_detail_id:
            messages.error(request, "User not found.")
        else:
            API().SetUserStatus(actor_id, target_detail_id, new_status,
                                "Status changed from dashboard")
            messages.success(request, "%s is now %s." % (user_id, new_status))
    except ValueError as exc:
        messages.error(request, str(exc))
    except Exception:
        logger.exception("set_account_status failed for %r", user_id)
        messages.error(request, "Unable to update the account status right now.")

    next_page = request.GET.get('next')
    if next_page not in ('admin_dashboard', 'manager_dashboard'):
        next_page = 'dashboard'
    return redirect(next_page)