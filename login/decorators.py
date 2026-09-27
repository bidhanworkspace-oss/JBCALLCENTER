from functools import wraps
from django.shortcuts import redirect
from django.contrib import messages
from django.db import connection

# Only users holding one of these roles pass the permission decorator,
# in addition to having the menu grant (SP_CHECK_USER_MENU_ACCESS).
APP_ROLES = ('SUPERADMIN', 'MANAGER', 'USER', 'BANK SUPPORT')


def has_menu_access(user_detail_id, url_name):
    """True when ``user_detail_id`` holds the menu whose URL_NAME is
    ``url_name``. Reads USER_MENU_ASSIGNMENT first and only falls back to the
    role grants, so an assign/remove made on the Assign Menu screen is
    authoritative. Returns False instead of raising."""
    if not user_detail_id or not url_name:
        return False
    try:
        with connection.cursor() as django_cursor:
            cursor = django_cursor.connection.cursor()
            has_access = cursor.var(int)
            cursor.callproc('SP_CHECK_USER_MENU_ACCESS',
                            [user_detail_id, url_name, has_access])
            return has_access.getvalue() == 1
    except Exception:
        return False


def permission_required_sp(url_name, any_role=False):
    """Gate a view on the user's menu grant.

    ``any_role=False`` (default) additionally requires the session role to be
    one of APP_ROLES, so an account with an unknown/legacy role can never open
    a page even if a menu row happens to be granted to it.

    ``any_role=True`` drops that role whitelist and trusts the menu grant
    alone. It is used by the User Unlock screen, which must be reachable by
    *any* account that has been given the 'user_unlock' menu.
    """
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
