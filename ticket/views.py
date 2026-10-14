from datetime import datetime

from django.shortcuts import render, redirect
from django.contrib import messages

from login.api import API
from login.decorators import permission_required_sp
from login.utils import get_session_user, save_upload

TICKETS_PER_PAGE = 15


TICKET_ISSUE_TYPES = [
    {'id': 1, 'name': 'New Registration'},
    {'id': 2, 'name': 'Unlock'},
    {'id': 3, 'name': 'Device Inactive'},
    {'id': 4, 'name': 'Disabled User'},
    {'id': 5, 'name': 'NID/DOB Change'},
    {'id': 6, 'name': 'Email Update'},
    {'id': 7, 'name': 'Temporary Password Send'},
    {'id': 8, 'name': 'Failed Transaction'},
]

TICKET_PRIORITIES = ['VERY HIGH', 'HIGH', 'LOW']

TICKET_STATUSES = {
    'OPEN': 'Open',
    'IN_PROGRESS': 'In Progress',
    'SOLVED': 'Solved',
    'DENIED': 'Denied',
}

TICKET_ALLOWED_EXTENSIONS = ('.jpg', '.jpeg', '.png', '.pdf')
TICKET_MAX_UPLOAD_BYTES = 5 * 1024 * 1024


def get_oracle_cursor():
    """Return (connection, cursor) using the same method as the API class."""
    conn = API._get_connection()
    cursor = conn.cursor()
    return conn, cursor


def parse_date(value):
    """Parse a YYYY-MM-DD string into a date, returning None when invalid."""
    try:
        return datetime.strptime((value or '').strip(), '%Y-%m-%d').date()
    except (TypeError, ValueError):
        return None


def map_ticket_row(row):
    """Turn an SP_GET_TICKETS / SP_SEARCH_TICKETS row into a dict."""
    status = row[7]
    return {
        'ticket_id': row[0],
        'ticket_ref': row[1],
        'issue_type': row[2],
        'customer_name': row[3],
        'mobile_no': row[4],
        'account_no': row[5],
        'priority': row[6],
        'status': status,
        'status_label': TICKET_STATUSES.get(status, status.title()),
        'raised_by_user_id': row[8],
        'created_at': row[9],
        'response_count': row[10],
        'open_days': row[11],
    }


def load_all_ticket_rows(filter_mode):
    """Legacy loader: every ticket row via SP_GET_TICKETS.

    Returns (rows, ok). ``ok`` is False only when the call itself failed.
    """
    conn = None
    try:
        conn, cursor = get_oracle_cursor()
        tickets_cur = cursor.connection.cursor()
        cursor.callproc('SP_GET_TICKETS', [filter_mode, tickets_cur])
        rows = list(tickets_cur)
        tickets_cur.close()
        return rows, True
    except Exception:
        return [], False
    finally:
        if conn:
            try:
                conn.close()
            except Exception:
                pass


def search_ticket_rows(filter_mode, ticket_no, mobile_no,
                       date_from, date_to, offset, limit):
    """DB-side filtered + paginated fetch via SP_SEARCH_TICKETS.

    Returns (rows, total, ok). ``ok`` is False when the procedure is not
    available (e.g. the migration was not applied yet) or the call failed, so
    the caller can fall back to the legacy, in-Python behaviour.
    """
    conn = None
    try:
        conn, cursor = get_oracle_cursor()
        tickets_cur = cursor.connection.cursor()
        total_var = cursor.var(int)
        cursor.callproc('SP_SEARCH_TICKETS', [
            filter_mode,
            ticket_no or None,
            mobile_no or None,
            date_from or None,
            date_to or None,
            offset,
            limit,
            tickets_cur,
            total_var,
        ])
        rows = list(tickets_cur)
        tickets_cur.close()
        return rows, (total_var.getvalue() or 0), True
    except Exception:
        return [], 0, False
    finally:
        if conn:
            try:
                conn.close()
            except Exception:
                pass


class TicketPage:
    """Minimal page object exposing the attributes tickets.html relies on."""

    def __init__(self, rows, number, per_page, total):
        self.rows = rows
        self.number = number
        self.per_page = per_page
        self.count = total
        self.num_pages = max(1, (total + per_page - 1) // per_page) if total else 1
        self.paginator = self

    def __iter__(self):
        return iter(self.rows)

    @property
    def has_previous(self):
        return self.number > 1

    @property
    def has_next(self):
        return self.number < self.num_pages

    @property
    def previous_page_number(self):
        return self.number - 1

    @property
    def next_page_number(self):
        return self.number + 1

    @property
    def start_index(self):
        return 0 if not self.count else (self.number - 1) * self.per_page + 1

    @property
    def end_index(self):
        return min(self.number * self.per_page, self.count)


@permission_required_sp('raise_ticket')
def raise_ticket(request):
    if request.method == 'POST':
        user_detail_id = get_session_user(request)
        user_login_id = request.session.get('JB_UserID')

        issue_type_id = request.POST.get('issue_type')
        customer_name = request.POST.get('customer_name')
        mobile_no = request.POST.get('mobile_no')
        account_no = request.POST.get('account_no')
        remarks = request.POST.get('remarks')
        priority = request.POST.get('priority')

        try:
            issue_type_id = int(issue_type_id or 0)
        except (TypeError, ValueError):
            issue_type_id = 0

        issue_type_name = next(
            (it['name'] for it in TICKET_ISSUE_TYPES if it['id'] == issue_type_id), ''
        )

        valid = True
        if not user_detail_id:
            valid = False
        if issue_type_id not in [it['id'] for it in TICKET_ISSUE_TYPES]:
            messages.error(request, "Please select a valid issue type.")
            valid = False
        if priority not in TICKET_PRIORITIES:
            messages.error(request, "Please select a valid priority.")
            valid = False
        if not (mobile_no or account_no):
            messages.error(request, "Provide at least the customer Mobile No or Account No.")
            valid = False

        if not valid:
            return render(request, 'ticket/raise_ticket.html', {
                'issue_types': TICKET_ISSUE_TYPES,
                'priorities': TICKET_PRIORITIES,
            })

        try:
            attachment_path = save_upload(
                request, 'tickets', 'attachment',
                TICKET_ALLOWED_EXTENSIONS, TICKET_MAX_UPLOAD_BYTES
            )
        except ValueError as exc:
            messages.error(request, str(exc))
            return render(request, 'ticket/raise_ticket.html', {
                'issue_types': TICKET_ISSUE_TYPES,
                'priorities': TICKET_PRIORITIES,
            })

        conn = None
        try:
            conn, cursor = get_oracle_cursor()

            ticket_id = cursor.var(int)
            ticket_ref = cursor.var(str)
            success = cursor.var(int)
            msg = cursor.var(str)

            cursor.callproc('SP_RAISE_TICKET', [
                user_detail_id, user_login_id, issue_type_id, issue_type_name,
                customer_name, mobile_no, account_no, remarks,
                attachment_path, priority, ticket_id, ticket_ref, success, msg
            ])

            if success.getvalue() == 1:
                messages.success(
                    request,
                    f"Ticket {ticket_ref.getvalue()} raised successfully. Our team will respond shortly."
                )
                return redirect('tickets')
            else:
                messages.error(request, msg.getvalue())
        except Exception:
            messages.error(request, "Unable to raise the ticket right now. Please try again.")
        finally:
            if conn:
                try:
                    conn.close()
                except Exception:
                    pass

    return render(request, 'ticket/raise_ticket.html', {
        'issue_types': TICKET_ISSUE_TYPES,
        'priorities': TICKET_PRIORITIES,
    })


@permission_required_sp('tickets')
def tickets_list(request):
    filter_mode = request.GET.get('filter', 'latest').strip().upper()
    if filter_mode not in ('LATEST', 'PRIORITY'):
        filter_mode = 'LATEST'

    q_ticket = request.GET.get('ticket', '').strip()
    q_mobile = request.GET.get('mobile', '').strip()
    date_from_raw = request.GET.get('date_from', '').strip()
    date_to_raw = request.GET.get('date_to', '').strip()
    date_from = parse_date(date_from_raw)
    date_to = parse_date(date_to_raw)
    db_date_from = date_from_raw if date_from else None
    db_date_to = date_to_raw if date_to else None

    try:
        page_number = int(request.GET.get('page', 1))
    except (TypeError, ValueError):
        page_number = 1
    if page_number < 1:
        page_number = 1

    per_page = TICKETS_PER_PAGE
    offset = (page_number - 1) * per_page

    rows, total, used_db = search_ticket_rows(
        filter_mode, q_ticket, q_mobile, db_date_from, db_date_to, offset, per_page
    )

    if used_db:
        num_pages = max(1, (total + per_page - 1) // per_page) if total else 1
        if total and page_number > num_pages:
            page_number = num_pages
            offset = (page_number - 1) * per_page
            rows, total, used_db = search_ticket_rows(
                filter_mode, q_ticket, q_mobile, db_date_from, db_date_to,
                offset, per_page
            )
        if used_db:
            page_obj = TicketPage(
                [map_ticket_row(r) for r in rows], page_number, per_page, total
            )

    if not used_db:
        all_rows, load_ok = load_all_ticket_rows(filter_mode)
        if not load_ok:
            messages.error(request, "Unable to load tickets right now.")
        all_tickets = [map_ticket_row(r) for r in all_rows]

        if q_ticket:
            needle = q_ticket.lower()
            all_tickets = [
                t for t in all_tickets
                if needle in str(t['ticket_ref'] or '').lower()
            ]
        if q_mobile:
            needle = q_mobile.lower()
            all_tickets = [
                t for t in all_tickets
                if needle in str(t['mobile_no'] or '').lower()
            ]
        if date_from:
            all_tickets = [
                t for t in all_tickets
                if t['created_at'] and t['created_at'].date() >= date_from
            ]
        if date_to:
            all_tickets = [
                t for t in all_tickets
                if t['created_at'] and t['created_at'].date() <= date_to
            ]

        total = len(all_tickets)
        num_pages = max(1, (total + per_page - 1) // per_page) if total else 1
        if page_number > num_pages:
            page_number = num_pages
        start = (page_number - 1) * per_page
        page_obj = TicketPage(
            all_tickets[start:start + per_page], page_number, per_page, total
        )

    params = request.GET.copy()
    params.pop('page', None)
    pagination_qs = params.urlencode()
    filter_params = request.GET.copy()
    filter_params.pop('page', None)
    filter_params.pop('filter', None)
    filter_qs = filter_params.urlencode()

    return render(request, 'ticket/tickets.html', {
        'page_obj': page_obj,
        'filter_mode': filter_mode,
        'q_ticket': q_ticket,
        'q_mobile': q_mobile,
        'date_from_raw': date_from_raw,
        'date_to_raw': date_to_raw,
        'pagination_qs': pagination_qs,
        'filter_qs': filter_qs,
    })


@permission_required_sp('tickets')
def ticket_detail(request, ticket_id):
    user_detail_id = get_session_user(request)
    user_login_id = request.session.get('JB_UserID')
    actor_role = request.session.get('JB_RoleName', '')
    can_take_action = (actor_role or '').strip().lower() == 'bank support'

    if request.method == 'POST' and not can_take_action:
        messages.error(request, "You do not have permission to respond to tickets.")
        return redirect('ticket_detail', ticket_id=ticket_id)

    if request.method == 'POST':
        action = request.POST.get('action')
        remarks = request.POST.get('remarks')

        if action not in ('SOLVED', 'DENIED', 'NOTE'):
            action = 'NOTE'

        conn = None
        try:
            conn, cursor = get_oracle_cursor()

            success = cursor.var(int)
            msg = cursor.var(str)

            cursor.callproc('SP_RESPOND_TICKET', [
                ticket_id, user_detail_id, user_login_id, action, remarks, success, msg
            ])

            if success.getvalue() == 1:
                if action == 'NOTE':
                    messages.success(request, "Note added to the ticket.")
                else:
                    messages.success(request, f"Ticket marked as {action}.")
            else:
                messages.error(request, msg.getvalue())
        except Exception:
            messages.error(request, "Unable to update the ticket right now.")
        finally:
            if conn:
                try:
                    conn.close()
                except Exception:
                    pass

        return redirect('ticket_detail', ticket_id=ticket_id)

    # GET request – load ticket + responses
    ticket = None
    responses = []
    conn = None
    try:
        conn, cursor = get_oracle_cursor()

        ticket_cur = cursor.connection.cursor()
        cursor.callproc('SP_GET_TICKET_BY_ID', [str(ticket_id), ticket_cur])

        for row in ticket_cur:
            status = row[9]
            ticket = {
                'ticket_id': row[0],
                'ticket_ref': row[1],
                'issue_type': row[2],
                'customer_name': row[3],
                'mobile_no': row[4],
                'account_no': row[5],
                'remarks': row[6],
                'attachment_path': row[7],
                'priority': row[8],
                'status': status,
                'status_label': TICKET_STATUSES.get(status, status.title()),
                'raised_by_user_id': row[10],
                'created_at': row[11],
            }
        ticket_cur.close()

        response_cur = cursor.connection.cursor()
        cursor.callproc('SP_GET_TICKET_RESPONSES', [str(ticket_id), response_cur])

        for row in response_cur:
            responses.append({
                'responder_user_id': row[0],
                'action': row[1],
                'remarks': row[2],
                'created_at': row[3],
            })
        response_cur.close()
    except Exception:
        messages.error(request, "Unable to load ticket details.")
    finally:
        if conn:
            try:
                conn.close()
            except Exception:
                pass

    if not ticket:
        messages.error(request, "Ticket not found.")
        return redirect('tickets')

    return render(request, 'ticket/ticket_detail.html', {
        'ticket': ticket,
        'responses': responses,
        'can_take_action': can_take_action,
    })