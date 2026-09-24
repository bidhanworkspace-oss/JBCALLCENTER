"""Custom API layer used by the User Unlock / Manage User screens.

The views in ``login/views.py`` (``user_unlock``, ``unlock_user``) call this
class instead of running SQL directly. Each method maps 1:1 to the flow:

    GetUserByMobileNo / GetUserStatus                - search + dropdown
    GetUserStatusByStatusName / UpdateUserStatus     - status change / disable
    UnlockUserByBankID                               - one-click unlock
"""

from django.db import connection

# Canonical statuses. USERDETAIL.USERSTATUS is free varchar2 text, so the
# "status id" returned by GetUserStatusByStatusName is the same text value.
VALID_STATUSES = ('Enabled', 'Disabled', 'Locked')


class API:
    """Thin wrapper around the USERDETAIL / SYSTEM_ROLE tables (Oracle)."""

    # ------------------------------------------------------------------
    # Search
    # ------------------------------------------------------------------
    def GetUserByMobileNo(self, mobileno):
        """Return a list of dicts for every USERDETAIL row whose MOBILE_NO
        matches (case/space-insensitive). Empty list when nothing matches."""
        sql = """
            SELECT u.USERDETAILID,
                   u.USERID,
                   u.FULLNAME,
                   u.MOBILE_NO,
                   u.EMAIL,
                   u.USERSTATUS,
                   u.FAILED_ATTEMPTS,
                   u.ROLE_ID,
                   NVL(r.ROLE_NAME, 'No Role') AS ROLE_NAME
            FROM   USERDETAIL u
            LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
            WHERE  TRIM(u.MOBILE_NO) = TRIM(:mobile)
            ORDER  BY u.USERDETAILID DESC
        """
        rows = []
        with connection.cursor() as cursor:
            cursor.execute(sql, {'mobile': str(mobileno or '')})
            cols = [d[0].lower() for d in cursor.description]
            rows = [dict(zip(cols, row)) for row in cursor.fetchall()]

        result = []
        for r in rows:
            result.append({
                'appuserinfoid': r.get('userdetailid'),
                'userid': r.get('userid'),
                'fullname': r.get('fullname'),
                'mobile': r.get('mobile_no'),
                'email': r.get('email'),
                'status': r.get('userstatus'),
                'role_name': r.get('role_name'),
                'role_id': r.get('role_id'),
                'failed_attempts': r.get('failed_attempts'),
            })
        return result

    # ------------------------------------------------------------------
    # Status list / status name normalization
    # ------------------------------------------------------------------
    def GetUserStatus(self):
        """Return the list of selectable statuses for the dropdown as
        [{'statusname': ..., 'appuserstatusid': ...}]."""
        return [{'statusname': s, 'appuserstatusid': s} for s in VALID_STATUSES]

    def GetUserStatusByStatusName(self, statusname):
        """Normalize a raw status string into one of the canonical statuses."""
        value = (statusname or '').strip().title()
        if value not in VALID_STATUSES:
            raise ValueError("Invalid status: %s" % (statusname or ''))
        return value

    # ------------------------------------------------------------------
    # Status change / disable (with the manager-vs-superadmin policy)
    # ------------------------------------------------------------------
    def UpdateUserStatus(self, appuserinfoid, appuserstatusid, updatedBy, remarks):
        """Apply a status change to one USERDETAIL row.

        Role policy (only 'Disabled'/'Locked' are restricted):
          - SUPERADMIN can disable/lock ANY user incl. Managers & Superadmins.
          - MANAGER can disable/lock any user EXCEPT a Superadmin.
          - anyone else is denied.
        """
        try:
            user_detail_id = int(appuserinfoid)
        except (TypeError, ValueError):
            raise ValueError("Invalid user info id: %s" % appuserinfoid)

        new_status = (appuserstatusid or '').strip().title()
        if new_status not in VALID_STATUSES:
            raise ValueError("Invalid status: %s" % appuserstatusid)

        self._enforce_status_policy(user_detail_id, new_status, updatedBy)

        with connection.cursor() as cursor:
            cursor.execute(
                "UPDATE USERDETAIL SET USERSTATUS = :status WHERE USERDETAILID = :id",
                {'status': new_status, 'id': user_detail_id},
            )
            return cursor.rowcount > 0

    # ------------------------------------------------------------------
    # One-click unlock (manager dashboard "Unlock" button)
    # ------------------------------------------------------------------
    def UnlockUserByBankID(self, bank_id, hashed_temp_pwd):
        """Delegate to SP_UNLOCK_USER_BY_MANAGER (resets password + enables).

        Returns {'success': bool, 'user_email': str, 'msg': str}."""
        with connection.cursor() as django_cursor:
            cursor = django_cursor.connection.cursor()
            email = cursor.var(str)
            success = cursor.var(int)
            msg = cursor.var(str)
            cursor.callproc('SP_UNLOCK_USER_BY_MANAGER', [
                str(bank_id), str(hashed_temp_pwd), email, success, msg,
            ])
            return {
                'success': success.getvalue() == 1,
                'user_email': email.getvalue(),
                'msg': msg.getvalue(),
            }

    # ------------------------------------------------------------------
    # helpers
    # ------------------------------------------------------------------
    def _enforce_status_policy(self, user_detail_id, new_status, updated_by):
        """Raise ValueError when the actor is not allowed to set this status
        on the target user."""
        if new_status == 'Enabled':
            return

        with connection.cursor() as cursor:
            cursor.execute(
                """SELECT NVL(UPPER(r.ROLE_NAME), '') AS ROLE_NAME
                   FROM   USERDETAIL u
                   LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
                   WHERE  u.USERDETAILID = :target_id""",
                {'target_id': user_detail_id},
            )
            target = cursor.fetchone()
        if not target:
            raise ValueError("Target user not found.")

        target_role = (target[0] or '').strip().upper()

        actor_role = self._role_of(updated_by)
        if actor_role == 'SUPERADMIN':
            return
        if actor_role == 'MANAGER':
            if target_role == 'SUPERADMIN':
                raise ValueError("Managers cannot disable/lock a Superadmin account. Only a Superadmin can disable a Superadmin.")
            return
        raise ValueError("Only a Superadmin or Manager can change a user's status.")

    def _role_of(self, user_id):
        """Return the UPPERCASE role name of the actor (by USERID) or ''."""
        if not user_id:
            return ''
        with connection.cursor() as cursor:
            cursor.execute(
                """SELECT NVL(UPPER(r.ROLE_NAME), '') AS ROLE_NAME
                   FROM   USERDETAIL u
                   LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
                   WHERE  TRIM(u.USERID) = TRIM(:actor_userid)""",
                {'actor_userid': str(user_id)},
            )
            row = cursor.fetchone()
        return (row[0] or '').strip().upper() if row else ''