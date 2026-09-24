from django.shortcuts import render, redirect
from django.db import connection
from django.contrib import messages

from login.decorators import permission_required_sp
from login.utils import get_session_user, save_upload


# ---------------------------------------------------------------------------
# Ticket configuration (kept in Python — the DB only stores the numeric/string
# values. All SQL lives inside stored procedures.)
# ---------------------------------------------------------------------------
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

# Extra attachments on tickets: images or PDF, max 5 MB.
TICKET_ALLOWED_EXTENSIONS = ('.jpg', '.jpeg', '.png', '.pdf')
TICKET_MAX_UPLOAD_BYTES = 5 * 1024 * 1024


# 1. RAISE A TICKET
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
            attachment_path = save_upload(request, 'tickets', 'attachment',
                                          TICKET_ALLOWED_EXTENSIONS, TICKET_MAX_UPLOAD_BYTES)
        except ValueError as exc:
            messages.error(request, str(exc))
            return render(request, 'ticket/raise_ticket.html', {
                'issue_types': TICKET_ISSUE_TYPES,
                'priorities': TICKET_PRIORITIES,
            })

        with connection.cursor() as django_cursor:
            cursor = django_cursor.connection.cursor()

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
                messages.success(request, f"Ticket {ticket_ref.getvalue()} raised successfully. Our team will respond shortly.")
                return redirect('tickets')
            else:
                messages.error(request, msg.getvalue())

    return render(request, 'ticket/raise_ticket.html', {
        'issue_types': TICKET_ISSUE_TYPES,
        'priorities': TICKET_PRIORITIES,
    })


# 2. TICKETS LIST (with Latest / High-priority filter)
@permission_required_sp('tickets')
def tickets_list(request):
    filter_mode = request.GET.get('filter', 'latest').strip().upper()
    if filter_mode not in ('LATEST', 'PRIORITY'):
        filter_mode = 'LATEST'

    tickets = []
    with connection.cursor() as django_cursor:
        cursor = django_cursor.connection.cursor()
        tickets_cur = cursor.connection.cursor()

        cursor.callproc('SP_GET_TICKETS', [filter_mode, tickets_cur])

        for row in tickets_cur:
            status = row[7]
            tickets.append({
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
            })
        tickets_cur.close()

    return render(request, 'ticket/tickets.html', {
        'tickets': tickets,
        'filter_mode': filter_mode,
        'status_labels': TICKET_STATUSES,
    })


# 3. TICKET DETAIL + RESPONSE/SOLVE
@permission_required_sp('tickets')
def ticket_detail(request, ticket_id):
    user_detail_id = get_session_user(request)
    user_login_id = request.session.get('JB_UserID')
    actor_role = request.session.get('JB_RoleName', '')
    can_take_action = actor_role == 'Bank Support'

    if request.method == 'POST' and not can_take_action:
        messages.error(request, "You do not have permission to respond to tickets.")
        return redirect('ticket_detail', ticket_id=ticket_id)

    if request.method == 'POST':
        action = request.POST.get('action')
        remarks = request.POST.get('remarks')

        if action not in ('SOLVED', 'DENIED', 'NOTE'):
            action = 'NOTE'

        with connection.cursor() as django_cursor:
            cursor = django_cursor.connection.cursor()

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

        return redirect('ticket_detail', ticket_id=ticket_id)

    ticket = None
    responses = []

    with connection.cursor() as django_cursor:
        cursor = django_cursor.connection.cursor()
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

    if not ticket:
        messages.error(request, "Ticket not found.")
        return redirect('tickets')

    return render(request, 'ticket/ticket_detail.html', {
        'ticket': ticket,
        'responses': responses,
        'status_labels': TICKET_STATUSES,
        'can_take_action': can_take_action,
    })