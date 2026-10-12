from functools import wraps
import oracledb
from django.shortcuts import redirect
from django.contrib import messages

from login.api import API

APP_ROLES = ('SUPERADMIN', 'MANAGER', 'USER', 'BANK SUPPORT')


def has_menu_access(user_detail_id, url_name):
    if not user_detail_id or not url_name:
        return False
    try:
        conn = API._get_connection()
        try:
            cursor = conn.cursor()
            has_access = cursor.var(int)
            cursor.callproc('SP_CHECK_USER_MENU_ACCESS',
                            [user_detail_id, url_name, has_access])
            result = has_access.getvalue() == 1
            cursor.close()
            return result
        finally:
            conn.close()
    except Exception:
        return False


def permission_required_sp(url_name, any_role=False):
    def decorator(view_func):
        @wraps(view_func)
        def _wrapped_view(request, *args, **kwargs):
            user_id = request.session.get('JB_UserDetailID')
            if not user_id:
                return redirect('login_page')

            if not any_role:
                role = (request.session.get('JB_RoleName') or '').strip().upper()
                if role not in APP_ROLES:
                    messages.error(request, "Access Denied: Your role is not recognized.")
                    return redirect('dashboard')

            if has_menu_access(user_id, url_name):
                return view_func(request, *args, **kwargs)

            messages.error(
                request,
                "Access Denied: You do not have permission to view this section.",
            )
            return redirect('dashboard')

        return _wrapped_view
    return decorator
