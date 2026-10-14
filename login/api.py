import logging
import json
import oracledb
from login.apiresponse import ApiResponse
from login.clsemail import clsMail
from login.clssecurity import clsSecurity
import requests
from django.conf import settings
from login.eJanataUserInfo import eJanataUserInfo
from timeit import default_timer as timer

logger = logging.getLogger(__name__)


VALID_STATUSES = ('Enabled', 'Disabled', 'Locked')
MAX_LOGIN_ATTEMPTS = 3

HIDDEN_SIDEBAR_MENUS = frozenset({'acc_statement'})


def _ejanata_timeout():

    try:
        return int(getattr(settings, 'EJANATA_API_TIMEOUT', '') or 30)
    except (TypeError, ValueError):
        return 30

EJANATA_UNAVAILABLE_MESSAGE = (
    'The eJanata service is not responding right now. Please try again in a '
    'few minutes.'
)

EJANATA_STATEMENT_NOT_FOUND_MESSAGE = 'Account Statement Not Found'

_BODY_PREVIEW = 300


class API:
    """Thin wrapper around the USERDETAIL / SYSTEM_ROLE tables (Oracle)."""

    accesstokencallstarttime = -20.0
    accesstokencallendtime = 0.0
    accesstokensession = 0.0

    urlgetuserbymobileno = clsSecurity.decodestr(
        settings.EJANATA_APILINK).rstrip('/') + '/appuser/getappuserwithaccountbymobile'

    urlupdateappuserstatus = clsSecurity.decodestr(
        settings.EJANATA_APILINK).rstrip('/') + '/appuser/updateappuserstatusidlockcountdatebyappuserinfoid'

    urlgetsolutionaccesstoken = clsSecurity.decodestr(
        settings.EJANATA_APILINK).rstrip('/') + '/token/getsolutionaccesstoken'

    urlaccstatement = clsSecurity.decodestr(
        settings.EJANATA_APILINK).rstrip('/') + '/v3.0/account/cbsminiaccountstatementbyaccountno'


    #urlgetuserbymobileno = settings.EJANATA_APILINK + '/appuser/getappuserwithaccountbymobile'
#
    #urlupdateappuserstatus = settings.EJANATA_APILINK + '/appuser/updateappuserstatusidlockcountdatebyappuserinfoid'
#
    #urlgetsolutionaccesstoken = settings.EJANATA_APILINK + '/token/getsolutionaccesstoken'

    #urlaccstatement = clsSecurity.decodestr(
    #    settings.EJANATA_APILINK).rstrip('/') + str(
    #    getattr(settings, 'EJANATA_ACC_STATEMENT_ENDPOINT', '') or ''
    #).strip()
#
    @staticmethod
    def dbConnectionEJanataStr():
        HOST = clsSecurity.decodestr(settings.EJANATA_HOST)
        USER = clsSecurity.decodestr(settings.EJANATA_USER)
        PASSWORD = clsSecurity.decodestr(settings.EJANATA_PASSWORD)
        PORT = clsSecurity.decodestr(settings.EJANATA_PORT)
        SCHEMA = clsSecurity.decodestr(settings.EJANATA_SCHEMA)
        connStr = USER + '/' + PASSWORD + '@' + HOST + ':' + PORT + '/' + SCHEMA
        return connStr

    @staticmethod
    def _get_connection():
        return oracledb.connect(API.dbConnectionEJanataStr())

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
        conn = API._get_connection()
        try:
            with conn.cursor() as cursor:
                cursor.execute(sql, {'mobile': str(mobileno or '')})
                cols = [d[0].lower() for d in cursor.description]
                rows = [dict(zip(cols, row)) for row in cursor.fetchall()]
        finally:
            try:
                conn.close()
            except Exception:
                pass

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
    def GetUserByUserIDAndEmail(self, user_id, email):
        """Read-only lookup used by the forgot-password page.

        Returns the matching USERDETAIL row as a dict, or None when the given
        User ID and Email do not belong to the same account. No write happens
        here, so a wrong pair can never change a password.
        """
        if not (user_id or email):
            return None
        sql = """
            SELECT u.USERDETAILID,
                   u.USERID,
                   u.FULLNAME,
                   u.EMAIL,
                   u.USERSTATUS
            FROM   USERDETAIL u
            WHERE  TRIM(u.USERID) = TRIM(:p_uid)
              AND  TRIM(u.EMAIL) = TRIM(:p_email)
        """
        conn = API._get_connection()
        try:
            with conn.cursor() as cursor:
                cursor.execute(sql, {
                    'p_uid': str(user_id or ''),
                    'p_email': str(email or ''),
                })
                row = cursor.fetchone()
                if not row:
                    return None
                return {
                    'userdetailid': int(row[0]),
                    'userid': row[1],
                    'fullname': row[2],
                    'email': row[3],
                    'userstatus': row[4],
                }
        finally:
            try:
                conn.close()
            except Exception:
                pass

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

        conn = API._get_connection()
        try:
            cursor = conn.cursor()
            userid = cursor.var(str)
            success = cursor.var(int)
            msg = cursor.var(str)
            cursor.callproc('SP_SET_USER_STATUS', [
                actor_userdetailid, target_userdetailid, new_status,
                remarks or '', userid, success, msg,
            ])
            if success.getvalue() != 1:
                raise ValueError(msg.getvalue() or 'Status update was rejected.')
            cursor.close()
            return True
        finally:
            try:
                conn.close()
            except Exception:
                pass

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
            conn = API._get_connection()
            try:
                cursor = conn.cursor()
                attempts = cursor.var(int)
                disabled = cursor.var(int)
                status = cursor.var(str)
                cursor.callproc('SP_REGISTER_FAILED_LOGIN', [
                    detail_id, limit, attempts, disabled, status,
                ])
                result = int(attempts.getvalue() or 0)
                cursor.close()
                return result
            finally:
                conn.close()
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
            conn = API._get_connection()
            try:
                cursor = conn.cursor()
                cursor.callproc('SP_RESET_FAILED_LOGIN', [detail_id])
                cursor.close()
            finally:
                conn.close()
            return True
        except Exception:
            logger.exception("ResetFailedLoginAttempt failed for %r", userdetailid)
            return False

    # ------------------------------------------------------------------
    # Unlock - the User Unlock screen. Mobile number is the only input.
    #
    # The account unlocked here is a JB Call Center account: it owns a
    # USERDETAIL row, so the unlock is SP_UNLOCK_USER_BY_MOBILE and no HTTP
    # call is involved. That is what makes this screen work with the eJanata
    # API unreachable.
    #
    # An *eJanata* account lives in the other application and has no
    # USERDETAIL row; it is acted on over HTTP by
    # ::update_app_user_status below, which backs both the Unlock User and the
    # Disable eJanata User screens.
    # ------------------------------------------------------------------
    def UnlockUserByMobileNo(self, mobileno, hashed_temp_pwd=None):
        """Unlock the call center account that owns ``mobileno``.

        This is the whole point of the User Unlock screen: the operator types
        a mobile number and one call unlocks that user. When
        ``hashed_temp_pwd`` is supplied the account also gets a brand new
        temporary password (and IS_FIRST_LOGIN = 1) so the credentials can be
        emailed out; when it is omitted only the lock is cleared.

        Returns ``{'success', 'userid', 'user_email', 'status', 'msg'}``.
        """
        mobile = str(mobileno or '').strip()
        if not mobile:
            raise ValueError("Mobile number is required.")

        conn = API._get_connection()
        try:
            cursor = conn.cursor()
            userid = cursor.var(str)
            email = cursor.var(str)
            status = cursor.var(str)
            msg = cursor.var(str)
            success = cursor.var(int)          # <-- FIXED: was missing

            cursor.callproc('SP_UNLOCK_USER_BY_MOBILE', [
                mobile,
                hashed_temp_pwd if hashed_temp_pwd is not None else '',
                userid, email, status, msg, success,   # <-- pass success if the SP expects it
                # NOTE: Adjust the parameter list to match your actual SP signature.
                # If your SP does not have a success OUT parameter, remove it.
            ])

            result = {
                'success': success.getvalue() == 1 if success.getvalue() is not None else True,
                'userid': userid.getvalue(),
                'user_email': email.getvalue(),
                'status': status.getvalue(),
                'msg': msg.getvalue(),
            }
            cursor.close()
            return result
        finally:
            try:
                conn.close()
            except Exception:
                pass

    # ------------------------------------------------------------------
    # The eJanata application API. Mobile number in, eJanata account out.
    #
    # These target the OTHER application, so there is deliberately no Oracle
    # procedure behind any of them and nothing here touches USERDETAIL.
    # ------------------------------------------------------------------
    @staticmethod
    def _istokenrejected(apiResponse):
        """True when the answer says the *token* was refused.

        The same codes the mail API recognises (clsMail._tokenrejectcodes):
        469 is this host's answer for a token it will not accept ("Token
        Invalid") and 468 for one that never arrived ("Valid Token Missing").
        A non-200 HTTP status has already been folded into ResponseCode by
        :meth:`_ejanata_post_once`, so 401 and 403 are covered here too.
        """
        return str(apiResponse.ResponseCode or '').strip() in clsMail._tokenrejectcodes

    @staticmethod
    def _ejanata_post(request, url, body, action, solutioninfoid='', solutioncode=''):
        """POST to an eJanata endpoint.

        ``solutioninfoid`` / ``solutioncode`` select which solution the
        accesssoltoken is minted for. Search uses the default (JB0001);
        unlock/disable must pass the update pair (JB0004) or the host
        answers responsecode 469 "Token Invalid".
        """
        apiResponse = API._ejanata_post_once(
            request, url, body, action, solutioninfoid, solutioncode,
        )

        if not API._istokenrejected(apiResponse):
            return apiResponse

        logger.warning(
            "eJanata %s refused the access token (responsecode %r); retrying "
            "once with a fresh token (solutioncode=%r).",
            action, apiResponse.ResponseCode, solutioncode or 'default',
        )
        API.ReseteJanataTokenCache(solutioncode)
        try:
            clsMail.ResetTokenCache()
        except Exception:
            pass
        retry = API._ejanata_post_once(
            request, url, body, action, solutioninfoid, solutioncode,
        )
        return retry

    @staticmethod
    def _ejanata_post_once(request, url, body, action,
                           solutioninfoid='', solutioncode=''):
        apiResponse = ApiResponse()

        token = API.GeteJanataAccessToken(
            request, solutioninfoid=solutioninfoid, solutioncode=solutioncode,
        )
        if not token:
            logger.error(
                "No solution access token, so the eJanata %s was not attempted "
                "(solutioncode=%r).",
                action, solutioncode or 'default',
            )
            apiResponse.ResponseCode = 401
            apiResponse.Message = EJANATA_UNAVAILABLE_MESSAGE
            apiResponse.Status = 'failed'
            return apiResponse

        try:
            response = requests.post(
                url, headers={"accesssoltoken": token}, json=body,
                timeout=_ejanata_timeout(), verify=False,
            )
        except Exception as exc:
            logger.warning("eJanata %s call to %s failed: %s", action, url, exc)
            apiResponse.ResponseCode = 502
            apiResponse.Message = EJANATA_UNAVAILABLE_MESSAGE
            apiResponse.Status = 'failed'
            return apiResponse

        try:
            parse_json = response.json()
        except ValueError:
            parse_json = {}
        if not isinstance(parse_json, dict):
            parse_json = {}

        apiResponse.raw = parse_json
        # Key casing varies across eJanata endpoints — accept both forms.
        lowered = {str(k).lower(): v for k, v in parse_json.items()}
        apiResponse.ResponseCode = (
            lowered.get('responsecode')
            or lowered.get('response_code')
            or lowered.get('code')
        )
        apiResponse.Message = (
            lowered.get('message')
            or lowered.get('msg')
        )
        apiResponse.Status = lowered.get('status')

        if not parse_json:
            logger.error(
                "eJanata %s call to %s answered HTTP %s with a non-JSON body: %s",
                action, url, response.status_code,
                (response.text or '').strip()[:_BODY_PREVIEW],
            )
            apiResponse.ResponseCode = response.status_code
            apiResponse.Status = 'failed'
            apiResponse.Message = EJANATA_UNAVAILABLE_MESSAGE
        elif response.status_code != 200:
            logger.error(
                "eJanata %s call to %s answered HTTP %s: %s", action, url,
                response.status_code,
                parse_json.get('message') or 'no message given',
            )
            apiResponse.ResponseCode = response.status_code
            apiResponse.Status = 'failed'
            apiResponse.Message = (parse_json.get('message')
                                   or EJANATA_UNAVAILABLE_MESSAGE)

        return apiResponse

    def update_app_user_status(self, request, appuserinfoid, appuserstatusid,
                               remarks, passwordlockcount='0', updatedby='',
                               solutioninfoid='', solutioncode=''):
        """Set Appuserstatusid on one eJanata app user (unlock or disable).

        The accesssoltoken MUST be minted for the same solution pair that is
        sent in the body (EJANATA_UPDATE_USER_*). Using the search token
        (JB0001) here is what produces responsecode 469 "Token Invalid".
        """
        lockcount = str(passwordlockcount or '0').strip() or '0'
        appuserinfoid_str = str(appuserinfoid or '').strip()
        appuserstatusid_str = str(appuserstatusid or '').strip()
        solutioninfoid_str = str(solutioninfoid or '').strip()
        solutioncode_str = str(solutioncode or '').strip()
        updatedby_str = str(updatedby or '').strip()
        remarks_str = str(remarks or '').strip()

        body = {
            "solutioninfoid": solutioninfoid_str,
            "solutioncode": solutioncode_str,
            "appuserinfoid": appuserinfoid_str,
            "appuserstatusid": appuserstatusid_str,
            "passwordlockcount": lockcount,
            "updatedby": updatedby_str,
            "remarks": remarks_str,
        }
        return API._ejanata_post(
            request, API.urlupdateappuserstatus, body,
            'app user status update',
            solutioninfoid=solutioninfoid_str,
            solutioncode=solutioncode_str,
        )

    # ------------------------------------------------------------------
    # Account statement (menu permission: Acc Statement).
    #
    # This backs the mini statement shown *inside* the User Information panel of
    # the User Unlock and Disable eJanata User screens, so the three identifiers
    # it needs are the ones the mobile-number search already returned for that
    # customer (Appuserinfoid / Appusername / Cbsaccountno). They travel hidden
    # from the page, which is why no account number is ever typed here.
    #
    # Returns a plain dict rather than an ApiResponse because the screen needs
    # the transaction rows, not just a verdict:
    #     {'success': bool, 'message': str, 'transactions': [...]}
    # Never raises, so the view cannot go down on an API problem.
    # ------------------------------------------------------------------
    def GetAccountStatement(self, request, appuserinfoid, appusername, accountno):
        appuserinfoid = str(appuserinfoid or '').strip()
        appusername = str(appusername or '').strip()
        accountno = str(accountno or '').strip()

        if not accountno:
            return {
                'success': False,
                'message': EJANATA_STATEMENT_NOT_FOUND_MESSAGE,
                'transactions': [],
            }

        try:
            solutioncode = clsSecurity.decodestr(
                settings.EJANATASOLUTIONCODE).strip()
        except Exception:
            logger.exception(
                "Could not read EJANATASOLUTIONCODE; the account statement was "
                "not attempted."
            )
            solutioncode = ''

        if not solutioncode:
            logger.error(
                "EJANATASOLUTIONCODE is empty on this server; the account "
                "statement was not attempted."
            )
            return {
                'success': False,
                'message': EJANATA_UNAVAILABLE_MESSAGE,
                'transactions': [],
            }

        body = {
            "solutioncode": solutioncode,
            "appuserinfoid": appuserinfoid,
            "appusername": appusername,
            "accountno": accountno,
        }

        apiResponse = API._ejanata_post(
            request, API.urlaccstatement, body, 'account statement',
        )
        succeeded = str(apiResponse.ResponseCode) in ('200', '210')
        return {
            'success': succeeded,
            'message': '' if succeeded else EJANATA_STATEMENT_NOT_FOUND_MESSAGE,
            'transactions': (API._normalize_statement_rows(apiResponse.raw)
                             if succeeded else []),
        }

    @staticmethod
    def _normalize_statement_rows(raw):
        """Map the API's transaction rows onto the four keys the template shows.

        Row and field names are matched case-insensitively, because the same
        eJanata API is not consistent about casing between endpoints. A field
        the API did not send stays blank rather than being invented, and a row
        that is not an object is skipped. Nothing here interprets an amount or a
        direction: the view decides Debit vs Credit from the type text, so a
        statement amount is displayed exactly as the API reported it.
        """
        rows = raw.get('data') if isinstance(raw, dict) else None
        if isinstance(rows, dict):
            nested = rows.get('data')
            rows = nested if isinstance(nested, list) else [rows]
        if not isinstance(rows, list):
            return []

        def _field(row, *names):
            lowered = {str(k).strip().lower(): v for k, v in row.items()}
            for name in names:
                value = lowered.get(name)
                if value is not None and str(value).strip():
                    return str(value).strip()
            return ''

        normalized = []
        for row in rows:
            if not isinstance(row, dict):
                continue
            normalized.append({
                'txndate': _field(row, 'txndate', 'transactiondate', 'postingdate', 'date'),
                'amount': _field(row, 'amount', 'txnamount', 'transactionamount'),
                'type': _field(row, 'type', 'transactiontype', 'txntype',
                               'debitcredit', 'drcr'),
                'description': _field(row, 'description', 'transactiondesc',
                                      'narration', 'transactionnarrative',
                                      'particulars', 'details', 'remarks'),
            })
        return normalized

    # ------------------------------------------------------------------
    # One-click unlock of a LOCAL call center account
    # (manager dashboard "Unlock" button, Oracle SP_UNLOCK_USER_BY_MANAGER).
    # Contrast with ::ejanata_user_unlock above, which targets the other
    # application's user over HTTP.
    # ------------------------------------------------------------------
    def UnlockUserByBankID(self, bank_id, hashed_temp_pwd):
        """Delegate to SP_UNLOCK_USER_BY_MANAGER (resets password + enables).

        Returns {'success': bool, 'user_email': str, 'msg': str}."""
        conn = API._get_connection()
        try:
            cursor = conn.cursor()
            email = cursor.var(str)
            success = cursor.var(int)
            msg = cursor.var(str)
            cursor.callproc('SP_UNLOCK_USER_BY_MANAGER', [
                str(bank_id), str(hashed_temp_pwd), email, success, msg,
            ])
            result = {
                'success': success.getvalue() == 1,
                'user_email': email.getvalue(),
                'msg': msg.getvalue(),
            }
            cursor.close()
            return result
        finally:
            try:
                conn.close()
            except Exception:
                pass

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
        conn = API._get_connection()
        try:
            with conn.cursor() as cursor:
                cursor.execute(
                    "SELECT u.USERDETAILID FROM USERDETAIL u "
                    "WHERE TRIM(u.USERID) = TRIM(:p_uid)",
                    {'p_uid': str(user_id)},
                )
                row = cursor.fetchone()
            return int(row[0]) if row else ''
        finally:
            try:
                conn.close()
            except Exception:
                pass

    def _enforce_status_policy(self, user_detail_id, new_status, updated_by):
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
        conn = API._get_connection()
        try:
            with conn.cursor() as cursor:
                cursor.execute(
                    """SELECT NVL(UPPER(r.ROLE_NAME), '') AS ROLE_NAME
                       FROM   USERDETAIL u
                       LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
                       WHERE  u.USERDETAILID = :target_id""",
                    {'target_id': user_detail_id},
                )
                row = cursor.fetchone()
            return (row[0] or '').strip().upper() if row else ''
        finally:
            try:
                conn.close()
            except Exception:
                pass

    # Per-solution token cache: { solutioncode: (token, fetched_at, duration) }
    _token_cache = {}

    @staticmethod
    def ReseteJanataTokenCache(solutioncode=''):
        """Drop cached token(s). Empty solutioncode clears the default search token."""
        key = str(solutioncode or '').strip() or '__default__'
        API._token_cache.pop(key, None)
        if key == '__default__':
            API.accesstoken = None
            API.accesstokensession = 0.0
            API.accesstokencallstarttime = -20.0

    @staticmethod
    def GeteJanataAccessToken(request=None, solutioninfoid='', solutioncode=''):
        """Mint (or reuse) an accesssoltoken for a given eJanata solution.

        Search uses the default pair (EJANATASOLUTIONINFOID / EJANATASOLUTIONCODE
        = JB0001). Unlock/disable must pass the update pair
        (EJANATA_UPDATE_USER_* = JB0004); a token for the wrong solution is
        rejected with responsecode 469 "Token Invalid".
        """
        sid = str(solutioninfoid or '').strip()
        scode = str(solutioncode or '').strip()
        if not sid:
            try:
                sid = clsSecurity.decodestr(settings.EJANATASOLUTIONINFOID).strip()
            except Exception:
                sid = ''
        if not scode:
            try:
                scode = clsSecurity.decodestr(settings.EJANATASOLUTIONCODE).strip()
            except Exception:
                scode = ''

        cache_key = scode or '__default__'
        now = timer()
        cached = API._token_cache.get(cache_key)
        if cached:
            token, fetched_at, duration = cached
            # Renew 10 seconds before expiry
            if token and (now - fetched_at) < max(duration - 10, 0):
                return token

        try:
            accesskey = clsSecurity.decodestr(settings.ACCESSSOLKEY)
        except Exception:
            logger.exception("Could not decode ACCESSSOLKEY")
            return None

        my_body = {
            "solutioninfoid": sid,
            "solutioncode": scode,
        }
        my_header = {"accesskey": "Basic " + accesskey}

        try:
            response = requests.post(
                API.urlgetsolutionaccesstoken,
                headers=my_header,
                json=my_body,
                timeout=_ejanata_timeout(),
                verify=False,
            )
        except Exception as exc:
            logger.warning(
                "eJanata token request failed for solutioncode=%r: %s",
                scode, exc,
            )
            return None

        if response.status_code != 200:
            logger.error(
                "eJanata token request for solutioncode=%r answered HTTP %s: %s",
                scode, response.status_code,
                (response.text or '')[:_BODY_PREVIEW],
            )
            return None

        try:
            parse_json = response.json()
        except ValueError:
            logger.error(
                "eJanata token response was not JSON for solutioncode=%r: %s",
                scode, (response.text or '')[:_BODY_PREVIEW],
            )
            return None

        if not isinstance(parse_json, dict):
            return None

        lowered = {str(k).lower(): v for k, v in parse_json.items()}
        code = str(lowered.get('responsecode') or lowered.get('code') or '').strip()
        token = (
            lowered.get('accesstoken')
            or lowered.get('access_token')
            or lowered.get('token')
        )
        try:
            duration = int(lowered.get('duration') or 0)
        except (TypeError, ValueError):
            duration = 0

        if code != '200' or not token:
            logger.error(
                "eJanata token request for solutioncode=%r failed: "
                "code=%r message=%r",
                scode, code, lowered.get('message'),
            )
            return None

        API._token_cache[cache_key] = (token, now, duration or 300)
        # Keep legacy class attrs in sync for the default (search) solution
        if cache_key == '__default__' or scode == clsSecurity.decodestr(
                settings.EJANATASOLUTIONCODE).strip():
            API.accesstoken = token
            API.accesstokensession = duration or 300
            API.accesstokencallstarttime = now

        return token

    def GeteJanataUserByMobileNo(self, request, mobileno, solutioncode, confirmationtypeid):

        if not clsSecurity.decodestr(settings.EJANATA_APILINK):
            logger.error(
                "eJanata user search was not attempted: EJANATA_APILINK is "
                "not configured."
            )

        if not settings.EJANATA_APILINK:
            logger.error(
                "eJanata user search was not attempted: EJANATA_APILINK is "
                "not configured."
            )

            apiResponse = ApiResponse()
            apiResponse.ResponseCode = 0
            apiResponse.Message = EJANATA_UNAVAILABLE_MESSAGE
            apiResponse.Status = 'failed'
            return apiResponse

        apiResponse = API._ejanata_post(request, API.urlgetuserbymobileno, {
            "solutioncode": solutioncode,
            "mobileno": mobileno,
            "confirmationtypeid": confirmationtypeid,
        }, 'user search')

        # Build the user DTO whenever the body carries a customer record.
        # ResponseCode 200 is the normal success; 210 is an accepted update.
        # Even on other codes, try to parse so a non-standard success is not lost.
        user = API.GeteJanataUserFromDatas(apiResponse.raw)
        if user is not None:
            apiResponse.data = user
        elif str(apiResponse.ResponseCode) in ('200', '210'):
            # Success code but no parseable customer — keep data unset.
            apiResponse.data = None

        return apiResponse

    @staticmethod
    def GeteJanataUserFromDatas(data):
        """Build an eJanataUserInfo out of a getappuserwithaccountbymobile
        response.

        The response arrives in a 'data' list whose rows are PLAIN TEXT.
        Field names are matched CASE-INSENSITIVELY so PascalCase / camelCase /
        lowercase API keys all map onto the DTO fields.
        """
        user = eJanataUserInfo()

        # Accept the full response body, a nested data list, or a bare row.
        rows = None
        if isinstance(data, dict):
            rows = data.get('data')
            if rows is None:
                rows = data.get('Data')
            if rows is None and any(
                str(k).lower() in (
                    'appuserinfoid', 'mobileno', 'appusername', 'name',
                )
                for k in data.keys()
            ):
                rows = data
        elif isinstance(data, list):
            rows = data

        if isinstance(rows, dict):
            rows = [rows]
        if not isinstance(rows, list) or not rows:
            return None

        row = rows[0] if isinstance(rows[0], dict) else {}
        if not row:
            return None

        # Case-insensitive cell lookup (API key casing is not consistent).
        lowered = {str(k).strip().lower(): v for k, v in row.items()}

        def _value(fieldname):
            raw = lowered.get(str(fieldname).strip().lower())
            if raw is None or str(raw).strip().lower() in ('', 'none', 'null'):
                return ''
            if isinstance(raw, (list, tuple, dict, set)):
                return ''
            return str(raw).strip()

        for attribute in API._ejanata_dto_fields():
            setattr(user, attribute, _value(attribute))

        for attribute, fieldname in API._EJANATA_FIELD_ALIASES.items():
            aliasvalue = _value(fieldname)
            if aliasvalue and not getattr(user, attribute, None):
                setattr(user, attribute, aliasvalue)

        if not getattr(user, 'Name', None):
            user.Name = ' '.join(
                part for part in (_value('firstname'), _value('lastname')) if part
            )

        # Blank object means the row had no usable fields — treat as not found.
        has_any = any(
            str(getattr(user, attr, '') or '').strip()
            for attr in API._ejanata_dto_fields()
        )
        if not has_any:
            return None

        return user

    # DTO field -> API field, for the columns the API names differently from the
    # DTO field they belong to. Everything else is matched by name.
    _EJANATA_FIELD_ALIASES = {
        'Dob': 'dateofbirth',
        'Branchcode': 'verifiedbranchcode',
        # The mobile-number search returns the CBS account number as
        # ``accountno``, while the DTO column is ``Cbsaccountno``. Without this
        # mapping the value was dropped, so the account statement was fetched
        # with an empty account number.
        'Cbsaccountno': 'accountno',
    }

    @staticmethod
    def _ejanata_dto_fields():
        cached = API.__dict__.get('_ejanatadtofields')
        if cached is None:
            cached = tuple(
                field.name for field in eJanataUserInfo._meta.get_fields()
                if getattr(field, 'concrete', False)
                and not field.primary_key
            )
            API._ejanatadtofields = cached
        return cached