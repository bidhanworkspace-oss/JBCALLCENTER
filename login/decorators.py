from functools import wraps
from django.shortcuts import redirect
from django.contrib import messages
from django.db import connection

# Only users holding one of these roles pass the permission decorator,
# in addition to having the menu grant (SP_CHECK_USER_MENU_ACCESS).
APP_ROLES = ('SUPERADMIN', 'MANAGER', 'USER', 'BANK SUPPORT')


def permission_required_sp(url_name):
    def decorator(view_func):
        @wraps(view_func)
        def _wrapped_view(request, *args, **kwargs):
            user_id = request.session.get('JB_UserDetailID')
            if not user_id:
                return redirect('login_page')

            role = (request.session.get('JB_RoleName') or '').strip().upper()
            if role not in APP_ROLES:
                messages.error(request, "Access Denied: Your role is not recognized.")
                return redirect('dashboard')

            with connection.cursor() as django_cursor:
                cursor = django_cursor.connection.cursor()
                has_access = cursor.var(int)
                cursor.callproc('SP_CHECK_USER_MENU_ACCESS', [user_id, url_name, has_access])

                if has_access.getvalue() == 1:
                    return view_func(request, *args, **kwargs)
                else:
                    messages.error(request, "Access Denied: You do not have permission to view this section.")
                    return redirect('dashboard')

        return _wrapped_view
    return decorator