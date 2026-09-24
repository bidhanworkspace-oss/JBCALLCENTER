import json
from django.db import connection
from django.shortcuts import redirect
from django.utils.deprecation import MiddlewareMixin

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