import logging
import os
from django.conf import settings
from django.core.files.storage import FileSystemStorage
from django.core.mail import send_mail
from django.db import connection

logger = logging.getLogger(__name__)


def insertuserlog(request, user_detail_id, action_type,
                  url_path=None, http_method=None, response_status=200):
    """Record a user action through SP_RECORD_AUDIT_LOG (best-effort, never raises)."""
    try:
        if not user_detail_id:
            return False
        with connection.cursor() as cursor:
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
        return True
    except Exception as exc:
        logger.warning("insertuserlog failed (action=%r): %s", action_type, exc)
        return False


def get_session_user(request):
    """Return the logged-in user detail id (numeric) or None without raising."""
    return request.session.get('JB_UserDetailID')


def dispatch_email(subject, body, to_email):
    """Send an email and never raise. Returns True on success."""
    if not to_email:
        return False
    try:
        sent = send_mail(subject, body, settings.DEFAULT_FROM_EMAIL, [to_email], fail_silently=False)
        return bool(sent)
    except Exception as exc:
        logger.warning("Failed to dispatch email to %s (subject=%r): %s", to_email, subject, exc)
        return False


def save_upload(request, folder, field_name, allowed_exts, max_bytes):
    """Persist an uploaded file under MEDIA_ROOT/<folder>.
    Returns '/media/<folder>/<filename>' or None when no/empty file.
    Raises ValueError when the file is not allowed."""
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