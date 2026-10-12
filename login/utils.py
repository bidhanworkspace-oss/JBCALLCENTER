import logging
import os
import oracledb
from django.conf import settings
from django.core.files.storage import FileSystemStorage
from django.template.loader import render_to_string

from login.clsemail import clsMail
from login.api import API

logger = logging.getLogger(__name__)


def insertuserlog(request, user_detail_id, action_type,
                  url_path=None, http_method=None, response_status=200):
    try:
        if not user_detail_id:
            return False
        conn = API._get_connection()
        try:
            with conn.cursor() as cursor:
                cursor.callproc('SP_RECORD_AUDIT_LOG', [
                    user_detail_id,
                    request.session.get('JB_UserID', None),
                    request.session.get('JB_RoleName', 'ANONYMOUS'),
                    action_type,
                    url_path or request.path,
                    http_method or request.method,
                    request.META.get('REMOTE_ADDR', ''),
                    '',
                    response_status,
                ])
        finally:
            try:
                conn.close()
            except Exception:
                pass
        return True
    except Exception as exc:
        logger.warning("insertuserlog failed (action=%r): %s", action_type, exc)
        return False


def get_session_user(request):
    return request.session.get('JB_UserDetailID')


def dispatch_email(request, subject, to_email, **context):
    if not to_email:
        return False
    try:
        emailbody = render_to_string('login/email_body.html', context)
    except Exception as exc:
        logger.warning("Could not render the email body for %s: %s", to_email, exc)
        return False

    try:
        token = clsMail.GetAccessToken(request)
        responsedatas = clsMail.sendemail(subject, to_email, emailbody, token)
    except Exception as exc:
        logger.warning("Failed to dispatch email to %s (subject=%r): %s", to_email, subject, exc)
        return False

    if not responsedatas.get('success'):
        logger.warning(
            "Mail API did not confirm delivery to %s (subject=%r): %s",
            to_email, subject, responsedatas.get('message') or responsedatas,
        )
        return False
    return True


def save_upload(request, folder, field_name, allowed_exts, max_bytes):
    upload = request.FILES.get(field_name)
    if not upload:
        return None

    ext = os.path.splitext(upload.name)[1].lower()
    if ext not in allowed_exts:
        raise ValueError('Invalid file type. Only %s are allowed.' % ', '.join(allowed_exts).upper().replace('.', ''))
    if upload.size > max_bytes:
        raise ValueError('File is too large. Maximum allowed size is %.0f MB.' % (max_bytes / (1024 * 1024)))

    dest_dir = os.path.join(settings.MEDIA_ROOT, folder)
    os.makedirs(dest_dir, exist_ok=True)
    fs = FileSystemStorage(location=dest_dir)
    filename = fs.save(upload.name, upload)
    return '/media/%s/%s' % (folder, filename)