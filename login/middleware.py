import json
import logging
import oracledb

from django.contrib import messages
from django.shortcuts import redirect
from django.utils.deprecation import MiddlewareMixin

from login.api import API, HIDDEN_SIDEBAR_MENUS

logger = logging.getLogger(__name__)


def _fetch_user_menus(user_detail_id):
    try:
        conn = API._get_connection()
        try:
            cursor = conn.cursor()
            menu_cursor = conn.cursor()
            cursor.callproc('SP_GET_USER_MENUS', [str(user_detail_id), menu_cursor])

            menus = []
            for row in menu_cursor:
                url_name = row[2]
                menus.append({
                    'id': row[0],
                    'title': row[1],
                    'url_name': url_name,
                    'parent_id': row[3],
                    'icon': row[4],
                    'hidden': url_name in HIDDEN_SIDEBAR_MENUS,
                })
            menu_cursor.close()
            cursor.close()
        finally:
            conn.close()
        return menus
    except Exception:
        logger.exception("Could not reload menus for userdetailid=%r", user_detail_id)
        return None


def _fetch_user_status(user_detail_id):
    try:
        conn = API._get_connection()
        try:
            with conn.cursor() as cursor:
                cursor.execute(
                    "SELECT UPPER(NVL(USERSTATUS, 'Enabled')) FROM USERDETAIL "
                    "WHERE USERDETAILID = :id",
                    {'id': user_detail_id},
                )
                row = cursor.fetchone()
            return (row[0] or '').strip().upper() if row else None
        finally:
            conn.close()
    except Exception:
        logger.exception("Could not read status for userdetailid=%r", user_detail_id)
        return None


class UserSessionStateMiddleware(MiddlewareMixin):

    def process_request(self, request):
        user_detail_id = request.session.get('JB_UserDetailID')
        if not user_detail_id:
            return None

        if request.session.get('FORCE_PW_CHANGE'):
            return None

        if request.path.startswith('/static/') or request.path.startswith('/media/'):
            return None

        status = _fetch_user_status(user_detail_id)
        if status is None:
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
    API_CALL_ROUTES = (
        'user-unlock',
        'ejanata-user-unlock',
        'disable-ejanata-user',
        'acc-statement',
    )
    ACTION_GET_ROUTES = (
        ('manager', 'approve'),
        ('manager', 'unlock'),
    )

    def process_response(self, request, response):
        action_type = self.action_type_for(request)
        if action_type is None:
            return response

        user_id = request.session.get('JB_UserDetailID', None)
        user_login_id = request.session.get('JB_UserID', None)
        role_name = request.session.get('JB_RoleName', 'ANONYMOUS')
        ip_address = self.get_client_ip(request)

        request_data = {}
        if request.method in ['POST', 'PUT', 'PATCH']:
            request_data = request.POST.dict()
            for key in list(request_data):
                if 'password' in key.lower():
                    request_data[key] = '***REDACTED***'

        data_json = json.dumps(request_data) if request_data else ''

        try:
            conn = API._get_connection()
            try:
                with conn.cursor() as cursor:
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
            finally:
                try:
                    conn.close()
                except Exception:
                    pass
        except Exception:
            logger.warning(
                "Audit trail entry was not saved for %s %s",
                request.method, request.path, exc_info=True,
            )

        return response

    @classmethod
    def action_type_for(cls, request):
        if request.path.startswith('/static/') or request.path.startswith('/media/'):
            return None

        if request.headers.get('X-Requested-With') == 'XMLHttpRequest':
            return 'API_CALL'
        if 'application/json' in request.headers.get('Accept', ''):
            return 'API_CALL'

        parts = [p for p in request.path.strip('/').split('/') if p]
        if parts and parts[0] in cls.API_CALL_ROUTES:
            return 'API_CALL'

        if request.method in ('POST', 'PUT', 'PATCH', 'DELETE'):
            return 'SQL_CALL'
        if tuple(parts[:2]) in cls.ACTION_GET_ROUTES:
            return 'SQL_CALL'

        return None

    def get_client_ip(self, request):
        x_forwarded_for = request.META.get('HTTP_X_FORWARDED_FOR')
        if x_forwarded_for:
            return x_forwarded_for.split(',')[0]
        return request.META.get('REMOTE_ADDR')