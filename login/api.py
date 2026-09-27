"""Custom API layer used by the User Unlock and Disable/Enable screens.

The views in ``login/views.py`` (``user_unlock``, ``disable_enable``,
``unlock_user``, ``login_view``) call this class instead of running SQL
directly. Each method maps 1:1 to the flow:

    GetUserByMobileNo / GetUserStatus                - search + dropdown
    GetUserStatusByStatusName / SetUserStatus        - enable / disable
    UnlockUserByMobileNo                             - unlock by mobile number
    RegisterFailedLoginAttempt / ResetFailedLoginAttempt - 3-strike lockout

Role policy for every status change (enforced in Oracle by
``SP_SET_USER_STATUS``, mirrored here so the caller gets a clean message):

    SUPERADMIN -> any account, any status (manager or user)
    MANAGER    -> accounts whose role is exactly 'User', any status.
                  A Manager can never enable/disable a Superadmin,
                  a Manager, or a Bank Support account.
    anything else -> denied.

``UnlockUserByMobileNo`` is the *unlock* entry point. Its only input is the
mobile number typed on the User Unlock screen - it is deliberately NOT a
superadmin/manager-only operation: whoever holds the 'user_unlock' menu grant
may call it, and the menu grant itself is handed out from the Assign Menu
screen.
"""

import logging

from django.db import connection

logger = logging.getLogger(__name__)

# Canonical statuses. USERDETAIL.USERSTATUS is free varchar2 text, so the
# "status id" returned by GetUserStatusByStatusName is the same text value.
VALID_STATUSES = ('Enabled', 'Disabled', 'Locked')

# A wrong password this many times in a row disables the account for EVERY
# role (user, bank support, manager and superadmin alike). It is then only
# re-enabled from the Disable/Enable screen.
MAX_LOGIN_ATTEMPTS = 3


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
    def SetUserStatus(self, actor_userdetailid, target_userdetailid,
                      status, remarks=None):
        """Enable or disable one account.

        This is the single entry point used by the Disable/Enable screen. The
        Oracle procedure ``SP_SET_USER_STATUS`` owns the policy:

          - SUPERADMIN can enable/disable ANY user (manager or user).
          - MANAGER can enable/disable a user whose role is exactly 'User'.
          - nobody may change their own account.

        Returns True when the row was updated. Raises ValueError when the
        actor is not allowed to make this change.
        """
        new_status = self.GetUserStatusByStatusName(status)

        # Reject a forbidden change before touching the database; the Oracle
        # procedure applies the very same policy a second time.
        self._enforce_status_policy(target_userdetailid, new_status,
                                    updated_by=actor_userdetailid)

        with connection.cursor() as django_cursor:
            cursor = django_cursor.connection.cursor()
            userid = cursor.var(str)
            success = cursor.var(int)
            msg = cursor.var(str)
            cursor.callproc('SP_SET_USER_STATUS', [
                actor_userdetailid, target_userdetailid, new_status,
                remarks or '', userid, success, msg,
            ])
            if success.getvalue() != 1:
                raise ValueError(msg.getvalue() or 'Status update was rejected.')
            return True

    def UpdateUserStatus(self, appuserinfoid, appuserstatusid, updatedBy, remarks):
        """Backwards-compatible alias of :meth:`SetUserStatus`.

        ``updatedBy`` used to be the actor's *user id* text; it is now the
        actor's numeric detail id, which is what the session actually holds.
        """
        return self.SetUserStatus(
            self._detail_id_of_userid(updatedBy),
            appuserinfoid,
            appuserstatusid,
            remarks,
        )

    # ------------------------------------------------------------------
    # Failed-login tracking (3 wrong passwords -> account disabled)
    # ------------------------------------------------------------------
    def RegisterFailedLoginAttempt(self, userdetailid, max_attempts=None):
        """Count one wrong password and disable the account at the limit.

        Called by ``login_view`` every time a wrong password is submitted.
        Increments FAILED_ATTEMPTS and, when the counter reaches
        ``max_attempts`` (default MAX_LOGIN_ATTEMPTS = 3), sets
        USERSTATUS = 'Disabled'. Applies to every role - user, bank support,
        manager and superadmin alike.

        Returns the new attempt count (int) - 0 when the call failed.
        """
        limit = int(max_attempts or MAX_LOGIN_ATTEMPTS)
        try:
            detail_id = int(userdetailid)
        except (TypeError, ValueError):
            return 0

        try:
            with connection.cursor() as django_cursor:
                cursor = django_cursor.connection.cursor()
                attempts = cursor.var(int)
                disabled = cursor.var(int)
                status = cursor.var(str)
                cursor.callproc('SP_REGISTER_FAILED_LOGIN', [
                    detail_id, limit, attempts, disabled, status,
                ])
                return int(attempts.getvalue() or 0)
        except Exception:
            logger.exception("RegisterFailedLoginAttempt failed for %r", userdetailid)
            return 0

    def ResetFailedLoginAttempt(self, userdetailid):
        """Clear the wrong-password counter after a successful sign-in."""
        try:
            detail_id = int(userdetailid)
        except (TypeError, ValueError):
            return False

        try:
            with connection.cursor() as django_cursor:
                cursor = django_cursor.connection.cursor()
                cursor.callproc('SP_RESET_FAILED_LOGIN', [detail_id])
            return True
        except Exception:
            logger.exception("ResetFailedLoginAttempt failed for %r", userdetailid)
            return False

    def EnableUser(self, target_userdetailid, enabledBy, remarks=None):
        """Re-enable a disabled/locked account and clear FAILED_ATTEMPTS.

        Policy: a Superadmin may enable ANY account; a Manager may only
        enable an account whose role is exactly 'User'. Nobody may enable
        themselves. Raises ValueError when the actor is not allowed to.
        """
        actor_id = self._detail_id_of_userid(enabledBy)
        if not actor_id:
            raise ValueError("Only a Superadmin or a Manager can enable or disable a user.")
        return self.SetUserStatus(actor_id, target_userdetailid, 'Enabled', remarks)

    def DisableUser(self, target_userdetailid, disabledBy, remarks=None):
        """Disable an account. Same role policy as :meth:`EnableUser`."""
        actor_id = self._detail_id_of_userid(disabledBy)
        if not actor_id:
            raise ValueError("Only a Superadmin or a Manager can enable or disable a user.")
        return self.SetUserStatus(actor_id, target_userdetailid, 'Disabled', remarks)

    def IsUserEnabled(self, userdetailid):
        """True when the account exists and USERSTATUS is 'Enabled'."""
        try:
            detail_id = int(userdetailid)
        except (TypeError, ValueError):
            return False
        with connection.cursor() as cursor:
            cursor.execute(
                "SELECT UPPER(NVL(USERSTATUS, 'Enabled')) FROM USERDETAIL "
                "WHERE USERDETAILID = :id",
                {'id': detail_id},
            )
            row = cursor.fetchone()
        return bool(row) and row[0] == 'ENABLED'

    # ------------------------------------------------------------------
    # Unlock - the User Unlock screen. Mobile number is the only input.
    # ------------------------------------------------------------------
    def UnlockUserByMobileNo(self, mobileno, hashed_temp_pwd=None):
        """Unlock the account that owns ``mobileno``.

        This is the whole point of the User Unlock screen: the operator types
        a mobile number and one API call unlocks that user. When
        ``hashed_temp_pwd`` is supplied the account also gets a brand new
        temporary password (and IS_FIRST_LOGIN = 1) so the credentials can be
        emailed out; when it is omitted only the lock is cleared.

        Returns ``{'success', 'userid', 'user_email', 'status', 'msg'}``.
        """
        mobile = str(mobileno or '').strip()
        if not mobile:
            raise ValueError("Mobile number is required.")

        with connection.cursor() as django_cursor:
            cursor = django_cursor.connection.cursor()
            userid = cursor.var(str)
            email = cursor.var(str)
            status = cursor.var(str)
            success = cursor.var(int)
            msg = cursor.var(str)
            cursor.callproc('SP_UNLOCK_USER_BY_MOBILE', [
                mobile, hashed_temp_pwd, userid, email, status, success, msg,
            ])
            return {
                'success': success.getvalue() == 1,
                'userid': userid.getvalue(),
                'user_email': email.getvalue(),
                'status': status.getvalue(),
                'msg': msg.getvalue(),
            }

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
    def _detail_id_of_userid(self, user_id):
        """Accept either a numeric detail id or a 'JB10003' style user id and
        return the numeric USERDETAILID ('' when it cannot be resolved)."""
        if user_id in (None, ''):
            return ''
        text = str(user_id).strip()
        if text.lstrip('-').isdigit():
            return int(text)
        return self._detail_id_by_userid(text)

    def _detail_id_by_userid(self, user_id):
        with connection.cursor() as cursor:
            cursor.execute(
                "SELECT u.USERDETAILID FROM USERDETAIL u WHERE TRIM(u.USERID) = TRIM(:uid)",
                {'uid': str(user_id)},
            )
            row = cursor.fetchone()
        return int(row[0]) if row else ''

    def _enforce_status_policy(self, user_detail_id, new_status, updated_by):
        """Pre-flight role check for a status change.

        Mirrors the policy enforced by ``SP_SET_USER_STATUS`` so a forbidden
        request is rejected with a readable message and no DB write is even
        attempted. ``updated_by`` may be a numeric detail id or a 'JB10003'
        style user id.

          SUPERADMIN -> any account.
          MANAGER    -> accounts whose role is exactly 'USER' only.
          else       -> denied.
        """
        actor_id = self._detail_id_of_userid(updated_by)
        if not actor_id:
            raise ValueError("Only a Superadmin or a Manager can enable or disable a user.")

        actor_role = self._role_of_detail_id(actor_id)
        if actor_role not in ('SUPERADMIN', 'MANAGER'):
            raise ValueError("Only a Superadmin or a Manager can enable or disable a user.")

        try:
            target_id = int(user_detail_id)
        except (TypeError, ValueError):
            raise ValueError("Invalid user info id: %s" % user_detail_id)

        target_role = self._role_of_detail_id(target_id)
        if not target_role:
            raise ValueError("Target user not found.")

        if actor_id == target_id:
            raise ValueError("You cannot change the status of your own account.")

        if actor_role == 'SUPERADMIN':
            return

        # A Manager is limited to plain user accounts: no Superadmin, no
        # Manager and no Bank Support account can be enabled/disabled here.
        if target_role != 'USER':
            raise ValueError(
                "Access Denied: a Manager can only enable or disable a regular User "
                "account. A Superadmin must handle this account."
            )

    def _role_of_detail_id(self, user_detail_id):
        """Return the UPPERCASE role name of a user (by USERDETAILID) or ''."""
        try:
            user_detail_id = int(user_detail_id)
        except (TypeError, ValueError):
            return ''
        with connection.cursor() as cursor:
            cursor.execute(
                """SELECT NVL(UPPER(r.ROLE_NAME), '') AS ROLE_NAME
                   FROM   USERDETAIL u
                   LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
                   WHERE  u.USERDETAILID = :target_id""",
                {'target_id': user_detail_id},
            )
            row = cursor.fetchone()
        return (row[0] or '').strip().upper() if row else ''
