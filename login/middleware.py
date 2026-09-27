import json
import logging

from django.contrib import messages
from django.db import connection
from django.shortcuts import redirect
from django.utils.deprecation import MiddlewareMixin

logger = logging.getLogger(__name__)


def _fetch_user_menus(user_detail_id):
    """Read the user's current menu grants straight from the database.

    Never raises - a failure simply leaves the sidebar untouched instead of
    breaking the page.
    """
    try:
        with connection.cursor() as django_cursor:
            cursor = django_cursor.connection.cursor()
            menu_cursor = cursor.connection.cursor()
            cursor.callproc('SP_GET_USER_MENUS', [str(user_detail_id), menu_cursor])

            menus = [{
                'id': row[0],
                'title': row[1],
                'url_name': row[2],
                'parent_id': row[3],
                'icon': row[4],
            } for row in menu_cursor]
            menu_cursor.close()
        return menus
    except Exception:
        logger.exception("Could not reload menus for userdetailid=%r", user_detail_id)
        return None


def _fetch_user_status(user_detail_id):
    """Return UPPER(USERSTATUS) for the user, or None when unavailable."""
    try:
        with connection.cursor() as cursor:
            cursor.execute(
                "SELECT UPPER(NVL(USERSTATUS, 'Enabled')) FROM USERDETAIL "
                "WHERE USERDETAILID = :id",
                {'id': user_detail_id},
            )
            row = cursor.fetchone()
        return (row[0] or '').strip().upper() if row else None
    except Exception:
        logger.exception("Could not read status for userdetailid=%r", user_detail_id)
        return None


class UserSessionStateMiddleware(MiddlewareMixin):
    """Keep the signed-cookie session in step with the database.

    The session cookie is only written at login, so without this middleware a
    menu removed on the Assign Menu screen kept showing on the sidebar of the
    already logged-in user, and a user disabled by an administrator kept
    browsing until their cookie expired.

    On every authenticated request this middleware:
      * reloads USER_MENUS from SP_GET_USER_MENUS, so an assign/remove applies
        at once - the next page load is all it takes, no re-login needed;
      * re-reads USERSTATUS and signs the user out when the account is no
        longer Enabled (or no longer exists), so a disabled user cannot keep
        working in an open browser tab.

    It is placed after ForcePasswordChangeMiddleware, so a first-login user
    who is still locked onto the change-password page never pays for these two
    queries and never has their restricted sidebar overwritten.
    """

    def process_request(self, request):
        user_detail_id = request.session.get('JB_UserDetailID')
        if not user_detail_id:
            return None

        # A locked first-login session keeps its single "Change Password" entry.
        if request.session.get('FORCE_PW_CHANGE'):
            return None

        if request.path.startswith('/static/') or request.path.startswith('/media/'):
            return None

        status = _fetch_user_status(user_detail_id)
        if status is None:
            # Database hiccup: fail open, do not log the user out on a read error.
            return None

        if status != 'ENABLED':
            request.session.flush()
            messages.error(
                request,
                "Your account is currently %s. You have been signed out. Please "
                "contact your Manager or Superadmin to enable it again." % status.title(),
            )
            return redirect('login_page')

        menus = _fetch_user_menus(user_detail_id)
        if menus is not None:
            request.session['USER_MENUS'] = menus
            request.session['JB_Status'] = status.title()

        return None


class ForcePasswordChangeMiddleware(MiddlewareMixin):
    """Lock a user with IS_FIRST_LOGIN / FORCE_PW_CHANGE into the
    change-password flow only. Every other URL redirects to the
    force-change-password page until the password has been changed."""

    ALLOWED_PREFIXES = (
        '/force-change-password/',
        '/change-password/',
        '/logout/',
        '/static/',
        '/media/',
    )

    def process_request(self, request):
        if not request.session.get('FORCE_PW_CHANGE'):
            return None
        if request.path.startswith(self.ALLOWED_PREFIXES):
            return None
        return redirect('force_change_password')


class NoCacheAuthenticatedMiddleware(MiddlewareMixin):
    NO_CACHE_HEADERS = {
        'Cache-Control': 'no-store, no-cache, must-revalidate, max-age=0',
        'Pragma': 'no-cache',
        'Expires': '0',
    }

    def process_response(self, request, response):
        if request.session.get('JB_UserDetailID'):
            for header, value in self.NO_CACHE_HEADERS.items():
                response[header] = value
        return response


class AuditTrailMiddleware(MiddlewareMixin):
    def process_response(self, request, response):
        # Exclude static/media files from log clutter
        if request.path.startswith('/static/') or request.path.startswith('/media/'):
            return response

        user_id = request.session.get('JB_UserDetailID', None)
        user_login_id = request.session.get('JB_UserID', None)
        role_name = request.session.get('JB_RoleName', 'ANONYMOUS')

        action_type = f"HTTP_{request.method}"
        ip_address = self.get_client_ip(request)

        # Collect request data safely (sanitize sensitive inputs like passwords)
        request_data = {}
        if request.method in ['POST', 'PUT', 'PATCH']:
            request_data = request.POST.dict()
            if 'password' in request_data:
                request_data['password'] = '***REDACTED***'
            if 'new_password' in request_data:
                request_data['new_password'] = '***REDACTED***'

        data_json = json.dumps(request_data) if request_data else ''

        # Call Oracle Procedure to record audit entry
        try:
            with connection.cursor() as cursor:
                cursor.callproc('SP_RECORD_AUDIT_LOG', [
                    user_id,
                    user_login_id,
                    role_name,
                    action_type,
                    request.path,
                    request.method,
                    ip_address,
                    data_json,
                    response.status_code
                ])
        except Exception:
            pass  # Ensure middleware logging never interrupts user traffic

        return response

    def get_client_ip(self, request):
        x_forwarded_for = request.META.get('HTTP_X_FORWARDED_FOR')
        if x_forwarded_for:
            return x_forwarded_for.split(',')[0]
        return request.META.get('REMOTE_ADDR')