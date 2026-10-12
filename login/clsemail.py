import json
import logging
import threading
from timeit import default_timer as timer

import requests
from django.conf import settings

from login.clssecurity import clsSecurity

logger = logging.getLogger(__name__)


class clsMail:

    urlgetaccesstoken = clsSecurity.decodestr(settings.MAIL_API_APILINK)+"/token/getsolutionaccesstoken"
    urlsendmail = clsSecurity.decodestr(settings.MAIL_API_APILINK)+"/mail/sendmail"

    accesstokenexpiry = 0.0
    accesstoken = ''

    _tokenlock = threading.Lock()

    _defaulttokenttl = 120.0
    _mintokenttl = 15.0
    _maxtokenttl = 900.0

    _successcodes = ('200', '0', '1')

    _tokenrejectstatus = (401, 403)
    _tokenrejectcodes = ('401', '403', '469', '468')

    @staticmethod
    def _post(url, payload, headers):
        response = requests.post(
            url, json=payload, headers=headers, timeout=settings.MAIL_API_TIMEOUT,
        )
        return response.status_code, response.text

    @staticmethod
    def _plainvalue(name):
        return str(getattr(settings, name, '') or '').strip()

    @staticmethod
    def ResetTokenCache():
        clsMail.accesstoken = ''
        clsMail.accesstokenexpiry = 0.0

    @staticmethod
    def _tokenttl(rawduration):
        try:
            ttl = float(rawduration)
        except (TypeError, ValueError):
            ttl = clsMail._defaulttokenttl

        if ttl < clsMail._mintokenttl or ttl > clsMail._maxtokenttl:
            logger.warning(
                "Access token duration %r is not a usable lifetime; using %.0fs.",
                rawduration, clsMail._defaulttokenttl,
            )
            ttl = clsMail._defaulttokenttl

        return ttl

    @staticmethod
    def _parsebody(body):
        try:
            parse_json = json.loads(body) if body else {}
        except ValueError:
            parse_json = {}
        return parse_json if isinstance(parse_json, dict) else {}

    @staticmethod
    def _istokenrejected(statuscode, parse_json):
        if statuscode in clsMail._tokenrejectstatus:
            return True
        return str(parse_json.get('responsecode') or '').strip() in clsMail._tokenrejectcodes

    @staticmethod
    def sendemail(emailsubject, emailto, emailtemplate, token=None,
                  solutioninfoid=None, solutioncode=None):

        if solutioninfoid is None:
            solutioninfoid = clsMail._plainvalue('MAIL_API_SOLUTIONINFOID')
        if solutioncode is None:
            solutioncode = clsMail._plainvalue('MAIL_API_SOLUTIONCODE')

        if not (solutioninfoid and solutioncode):
            logger.error(
                "Mail API solution identity is not configured "
                "(MAIL_API_SOLUTIONINFOID / MAIL_API_SOLUTIONCODE)",
            )
            return {'responsecode': '500', 'status': 'failed',
                    'message': 'Mail API solution identity is not configured.',
                    'success': False}

        payload = {
            'solutioninfoid': solutioninfoid,
            'solutioncode': solutioncode,
            'emailsubject': emailsubject,
            'emailto': emailto,
            'emailtemplate': emailtemplate,
        }
        headers = {'Content-Type': 'application/json'}
        if token:
            headers['accesssoltoken'] = token

        try:
            statuscode, body = clsMail._post(
                clsMail.urlsendmail, payload, headers,
            )
        except Exception as exc:
            logger.warning("Mail API call failed for %s: %s", emailto, exc)
            return {'responsecode': '502', 'status': 'failed',
                    'message': 'Mail API call failed: %s' % exc, 'success': False}

        parse_json = clsMail._parsebody(body)

        if clsMail._istokenrejected(statuscode, parse_json):
            logger.warning(
                "Mail API refused the access token for %s (HTTP %s); "
                "retrying once with a fresh token.", emailto, statuscode,
            )
            clsMail.ResetTokenCache()
            refreshtoken = clsMail.GetAccessToken()
            if refreshtoken:
                headers['accesssoltoken'] = refreshtoken
                try:
                    statuscode, body = clsMail._post(
                        clsMail.urlsendmail, payload, headers,
                    )
                except Exception as exc:
                    logger.warning(
                        "Mail API retry failed for %s: %s", emailto, exc)
                    return {'responsecode': '502', 'status': 'failed',
                            'message': 'Mail API call failed: %s' % exc,
                            'success': False}
                parse_json = clsMail._parsebody(body)

        responsedata = dict(parse_json)
        responsedata.setdefault('responsecode', str(statuscode))
        if statuscode != 200:
            responsedata.setdefault('status', 'failed')
        responsedata.setdefault(
            'message', '' if statuscode == 200 else 'HTTP %s' % statuscode,
        )
        responsedata['success'] = clsMail._isdelivered(responsedata, statuscode)
        logger.info("Mail API response for %s: %s", emailto, responsedata)
        return responsedata

    @staticmethod
    def _isdelivered(responsedata, statuscode):
        if statuscode != 200:
            return False
        status = str(responsedata.get('status') or '').strip().lower()
        if status in ('failed', 'fail', 'error'):
            return False
        if 'succ' in status or 'sent' in status:
            return True
        responsecode = responsedata.get('responsecode')
        if responsecode is None:
            return True
        return str(responsecode).strip() in clsMail._successcodes

    @staticmethod
    def _configvalue(name):
        value = str(getattr(settings, name, '') or '').strip()
        if not value:
            return ''
        try:
            decoded = clsSecurity.decodestr(value).strip()
        except Exception as exc:
            logger.warning(
                "Setting %s is not valid base64 (%s); sending it unchanged.", name, exc,
            )
            return value
        return decoded or value

    @staticmethod
    def GetAccessToken(request=None):
        now = timer()
        if clsMail.accesstoken and now < clsMail.accesstokenexpiry:
            return clsMail.accesstoken

        with clsMail._tokenlock:
            now = timer()
            if clsMail.accesstoken and now < clsMail.accesstokenexpiry:
                return clsMail.accesstoken
            return clsMail._fetchtoken(request)

    @staticmethod
    def _fetchtoken(request=None):
        solutioninfoid = clsMail._configvalue('EJANATASOLUTIONINFOID')
        solutioncode = clsMail._configvalue('EJANATASOLUTIONCODE')
        accesskey = clsMail._configvalue('ACCESSSOLKEY')
        if not (solutioninfoid and solutioncode and accesskey):
            logger.error(
                "Solution mail credentials are not configured "
                "(EJANATASOLUTIONINFOID, EJANATASOLUTIONCODE, ACCESSSOLKEY)",
            )
            clsMail.ResetTokenCache()
            return ''

        my_body = {
            'solutioninfoid': solutioninfoid,
            'solutioncode': solutioncode,
        }
        my_header = {'accesskey': 'Basic ' + accesskey}

        try:
            statuscode, body = clsMail._post(
                clsMail.urlgetaccesstoken, my_body, my_header,
            )
        except Exception as exc:
            logger.warning("Could not obtain the solution access token: %s", exc)
            clsMail.ResetTokenCache()
            return ''

        parse_json = clsMail._parsebody(body)

        if statuscode != 200 or str(parse_json.get('responsecode')) != '200':
            logger.error(
                "Access token request rejected (HTTP %s): %s",
                statuscode, parse_json.get('message') or (body or '')[:200],
            )
            clsMail.ResetTokenCache()
            return ''

        token = str(parse_json.get('accesstoken') or '').strip()
        if not token:
            logger.error("Access token response carried no token: %s", (body or '')[:200])
            clsMail.ResetTokenCache()
            return ''

        ttl = clsMail._tokenttl(parse_json.get('duration'))

        clsMail.accesstoken = token
        clsMail.accesstokenexpiry = timer() + max(ttl * 0.9, clsMail._mintokenttl)
        return clsMail.accesstoken