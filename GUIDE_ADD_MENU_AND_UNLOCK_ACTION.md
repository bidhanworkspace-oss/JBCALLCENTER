# How to Add a New Menu (e.g. "User Unlock" / "Manage User")

This guide tells you exactly **where to change** to add a brand-new menu + its page,
following the same pattern as the existing **User Unlock** page:

| Concern           | Where it lives                                                                 |
|-------------------|--------------------------------------------------------------------------------|
| Menu definition   | Oracle `SYSTEM_MENU` table (DB)                                                |
| Permission grant  | Oracle `ROLE_MENU_PERMISSION` (role-based) and/or `USER_MENU_ASSIGNMENT` (per-user) |
| View logic        | `login/views.py`                                                               |
| URL               | `config/urls.py`                                                               |
| HTML page         | `templates/login/<name>.html`                                                  |
| API integration   | **Your** custom API class/method — see below                                    |

> Your API work is NOT done here. The view below shows where the `API()` class is
> *called*; you write the class and its methods yourself. Create `login/api.py`
> with an `API` class exposing the methods each screen needs, plus
> `UnlockUserByBankID(bank_id, hashed_temp_pwd)` returning
> `{'success': bool, 'user_email': str, 'msg': str}` for the manager's one-click
> unlock. Until the class exists, those pages show a friendly message with the
> import error instead of crashing.
>
> **The screens that take a mobile number own different users — keep them
> apart, because their data comes from different places:**
>
> | Screen | View | Users | Where the data comes from |
> |---|---|---|---|
> | Disable/Enable | `login.views.disable_enable` | **JB Call Center** | Oracle `USERDETAIL` — `api.GetUserByMobileNo(mobileno)`, `api.GetUserStatus()`, `api.SetUserStatus(...)` |
> | User Unlock | `login.views.user_unlock` | **JB Call Center** | Oracle `USERDETAIL` — `api.GetUserByMobileNo(mobileno)` to search, `api.UnlockUserByMobileNo(mobileno, hashed_pwd)` → `SP_UNLOCK_USER_BY_MOBILE` to unlock. No HTTP call, so it keeps working while the eJanata API is down |
> | eJanata User Unlock | `login.views.ejanata_user_unlock` | **eJanata** | The eJanata customer API — `api.GeteJanataUserByMobileNo(...)` to search, `api.ejanata_user_unlock(...)` to release |
> | Disable eJanata User | `login.views.disable_ejanata_user` | **eJanata** | The eJanata customer API — `api.GeteJanataUserByMobileNo(...)` to search, `api.ejanata_user_disable(...)` to block |
> | Acc Statement | `login.views.acc_statement` | **eJanata / core banking** | `api.GetAccountStatement(accno)` — Debit/Credit transaction list |
>
> An eJanata user has **no row** in `USERDETAIL`, so never call
> `GetUserByMobileNo` (or any `USERDETAIL` query) from `ejanata_user_unlock` or
> `disable_ejanata_user`: on a number collision it would return a different,
> unrelated local account. Conversely `disable_enable` and `user_unlock` must
> never call the eJanata API.
>
> **Three things belong to one screen and must never be shared with another:**
> the URL `name=`, the `SYSTEM_MENU.URL_NAME` and the template. `user_unlock`
> and `ejanata_user_unlock` once shared all three, which silently deleted the
> call center unlock screen — the eJanata view took the `'user_unlock'` route
> name and menu, and nothing then answered to `api.UnlockUserByMobileNo` any
> more. Each screen now has its own: `/user-unlock/` +
> `login/templates/login/user_unlock.html` vs `/ejanata-user-unlock/` +
> `login/templates/login/ejanata_user_unlock.html`. See
> `database/JB_CALLCENTER_EJANATA_USER_UNLOCK.sql` for the menu row.
>
> **Never put a technical error on screen.** These messages are read by call
> centre staff, so they carry no endpoint URL, no HTTP status, no raw response
> body and no Python exception — `API._ejanata_post` logs all of that with
> `logger.error` and returns one of `EJANATA_UNAVAILABLE_MESSAGE` /
> `EJANATA_VERIFY_FAILED_MESSAGE` instead. Keep new failures on that pattern:
> log the detail, show a sentence an operator can act on.

---

## 1. Database — register the menu

Add one row per URL you want permission-gated. Run in the `JBCALLCENTER` schema.

```sql
-- Visible page menu (appears in the sidebar).
INSERT INTO SYSTEM_MENU (MENU_TITLE, URL_NAME, ICON_CLASS, DISPLAY_ORDER)
VALUES ('Manage User', 'manage_user', 'bi-person-gear', 11);

-- Hidden action/lookup URLs (no sidebar item, but still permission-gated).
-- Attach them as children of an existing menu (used by the decorator).
DECLARE
  v_parent NUMBER;
BEGIN
  SELECT MENU_ID INTO v_parent FROM SYSTEM_MENU WHERE URL_NAME = 'dashboard';
  INSERT INTO SYSTEM_MENU (MENU_TITLE, URL_NAME, PARENT_ID, ICON_CLASS, DISPLAY_ORDER)
  VALUES ('Manage User Lookup', 'manage_user_lookup', v_parent, NULL, 30);
END;
/
COMMIT;
```

Grant to roles (or use the Assign Menu screen, which writes `USER_MENU_ASSIGNMENT`):

```sql
INSERT INTO ROLE_MENU_PERMISSION (ROLE_ID, MENU_ID)
SELECT r.ROLE_ID, m.MENU_ID
FROM   SYSTEM_ROLE r, SYSTEM_MENU m
WHERE  UPPER(r.ROLE_NAME) IN ('SUPERADMIN','MANAGER')
  AND  m.URL_NAME IN ('manage_user','manage_user_lookup')
  AND  NOT EXISTS (SELECT 1 FROM ROLE_MENU_PERMISSION x
                   WHERE x.ROLE_ID = r.ROLE_ID AND x.MENU_ID = m.MENU_ID);
COMMIT;
```

**Rule:** `URL_NAME` in `SYSTEM_MENU` must exactly match the URL `name=` you use in
Django, because `login/decorators.py:permission_required_sp(url_name)` calls
`SP_CHECK_USER_MENU_ACCESS(session_user, url_name)` and that procedure joins on
`SYSTEM_MENU.URL_NAME`.

**Role requirement:** the decorator also refuses users whose session role
(`JB_RoleName`) is not one of the four app roles — `SUPERADMIN`, `MANAGER`, `USER`,
`BANK SUPPORT` — even if the per-user menu grant exists. So a user must hold one of
those roles **and** have the menu permission to open the page.

---

## 2. Django — views in `login/views.py`

Add (a) the page view and (b) a lookup/action view. Your view is where you call
**your** custom API:

```python
from login.decorators import permission_required_sp

# ===== page: shows the mobile search box =====
@permission_required_sp('manage_user')
def manage_user(request):
    return render(request, 'login/manage_user.html')


# ===== lookup: receives the mobile number, calls YOUR API =====
# NOTE: this example is for a page that owns JB Call Center users, which do
# live in USERDETAIL. If your page is about eJanata users instead, swap
# GetUserByMobileNo for the eJanata customer API (GeteJanataUserByMobileNo) -
# see the ownership table at the top of this guide.
@permission_required_sp('manage_user_lookup')
def manage_user_lookup(request):
    from .your_api_module import API          # your custom API class

    mobileno = (request.GET.get('mobileno') or '').strip()
    if not mobileno:
        return JsonResponse({'success': False, 'message': 'Mobile number is required.'})

    api = API()
    info = api.GetUserByMobileNo(mobileno)     # <- your method, do not write it here
    userstatuslists = api.GetUserStatus()

    if not info:
        return JsonResponse({'success': False, 'message': 'No user found with that mobile number.'})

    return JsonResponse({'success': True, 'users': info, 'statuses': userstatuslists})
```

If you prefer the **path-parameter style** you pasted (`def manageuser(request, mobileno)`),
just add the URL with a `<str:mobileno>` converter (see below) and read the arg
instead of `request.GET`. The rest of your view (form POST for `btnupdateuser`, etc.)
goes exactly where you already have it.

### URLs in `config/urls.py`

```python
path('manage-user/', views.manage_user, name='manage_user'),
path('manage-user/api/lookup/', views.manage_user_lookup, name='manage_user_lookup'),
# optional path-parameter version:
# path('manage-user/<str:mobileno>/', views.manage_user, name='manage_user_by_mobile'),
```

---

## 3. Template — `templates/login/manage_user.html`

Copy `templates/login/user_unlock.html` and adjust the blocks
(`page_heading`, `page_title`, `page_sub`) and the JS.

### 3a. Taking the mobile number input (the part you asked about)

You only need an `<input>` + a **Search** button. Two ways to hand the number to
your view:

**Option A — navigate to a URL (server-side render).** Works with a
`def manage_user_page(request, mobileno)` or `?mobileno=` view. Submit the form:

```html
<form method="get" action="{% url 'manage_user_lookup' %}">
  <label for="mobile_no">Mobile Number</label>
  <input type="text" id="mobile_no" name="mobileno" inputmode="numeric"
         placeholder="e.g. 01712345678" required>
  <button type="submit" class="btn btn-primary">Search</button>
</form>
```

**Option B — fetch JSON (like `user_unlock.html`).** No page reload; your JS sends
the value and renders the result table:

```js
function doSearch() {
  var mobile = document.getElementById('mobile_no').value.trim();
  if (!mobile) { alert('Please enter a mobile number.'); return; }

  fetch('{% url "manage_user_lookup" %}?mobileno=' + encodeURIComponent(mobile))
    .then(function (r) { return r.json(); })
    .then(function (data) {
      // data.success / data.users — render your table row here
    });
}
// Enter key also triggers search
document.getElementById('mobile_no').addEventListener('keydown', function (e) {
  if (e.key === 'Enter') { e.preventDefault(); doSearch(); }
});
```

Optional, but keeps input clean (already used on the login page):

```js
mobileNoInput.addEventListener('input', function () {
  mobileNoInput.value = mobileNoInput.value.replace(/[^0-9]/g, '').slice(0, 15);
});
```

That is all the front end needs — your view receives the number as
`mobileno` (`request.GET.get('mobileno')` or the URL path arg) and calls your
`API()` class from there. You do the rest (matching in your API, rendering the
result list, and the POST "update/unlock" handler).

---

## 4. Where the "add another menu" checklist lives

To add *any* new menu end-to-end:

1. **DB:** insert into `SYSTEM_MENU` (`MENU_TITLE`, `URL_NAME`, `ICON_CLASS`,
   `DISPLAY_ORDER`, optional `PARENT_ID` for hidden action URLs).
2. **DB:** grant via `ROLE_MENU_PERMISSION` (roles) or assign per user from the
   **Assign Menu** screen (`USER_MENU_ASSIGNMENT`).
3. **View:** add the page view + action views in `login/views.py` decorated with
   `@permission_required_sp('<url_name>')`; call your `API()` class inside.
4. **URL:** add `path(...)` in `config/urls.py`; `name` must equal `URL_NAME`.
5. **Template:** `templates/login/<name>.html` extending `base.html`.
6. Restart the dev server (or it picks up code changes), log in as Superadmin →
   sidebar shows the new menu. A user without a grant sees "Access Denied".

---

## 5. Reference — how the two User Unlock screens are wired

### 5a. User Unlock — call center account (Oracle `USERDETAIL`)

| Concern      | Procedure / URL / view                                       |
|--------------|--------------------------------------------------------------|
| Input        | same view, reads `mobileno` (`request.POST`/`GET`/path)      |
| Search       | POST `btnfetchuser` → `api.GetUserByMobileNo(mobileno)` → the matching `USERDETAIL` row(s), shown before anything is changed |
| Action       | same view, POST `btnunlockuser` → `api.UnlockUserByMobileNo(mobileno, hashed_pwd)` → `SP_UNLOCK_USER_BY_MOBILE` (re-enables, clears `FAILED_ATTEMPTS`, installs a temp password, which is emailed to the account) |
| Page view    | `login.views.user_unlock` → `login/templates/login/user_unlock.html` |
| URLs         | `/user-unlock/` and `/user-unlock/<str:mobileno>/`           |
| Permissions  | `SYSTEM_MENU.URL_NAME = 'user_unlock'` via `ROLE_MENU_PERMISSION`/`USER_MENU_ASSIGNMENT` |

### 5b. eJanata User Unlock — application user of the other system (HTTP)

| Concern      | Procedure / URL / view                                       |
|--------------|--------------------------------------------------------------|
| Input        | same view, reads `mobileno` (`request.POST`/`GET`/path)      |
| Search       | POST `btnfetchuser` → `api.GeteJanataUserByMobileNo(...)` → the eJanata customer, shown with its eJanata status flags |
| Action       | same view, POST `btnunlockuser` → `api.ejanata_user_unlock(...)` → the eJanata unlock endpoint (`EJANATA_UNLOCK_USER_ENDPOINT`) |
| Page view    | `login.views.ejanata_user_unlock` → `login/templates/login/ejanata_user_unlock.html` |
| URLs         | `/ejanata-user-unlock/` and `/ejanata-user-unlock/<str:mobileno>/` |
| Permissions  | `SYSTEM_MENU.URL_NAME = 'ejanata_user_unlock'` (see `database/JB_CALLCENTER_EJANATA_USER_UNLOCK.sql`) |

Both screens take a mobile number and both have a search step, which is exactly
why they must not share a route name, a menu or a template. The rule to copy:
look the user up **only** in the system that owns it, then act there —
`GetUserByMobileNo` for a call center account, `GeteJanataUserByMobileNo` for an
eJanata one. A number can exist on both sides, and the wrong lookup then shows
the wrong person.

---

## 6. Restricting a page to SuperAdmin only

Granting the menu to the Superadmin role is **not** enough on its own:
`USER_MENU_ASSIGNMENT` wins over `ROLE_MENU_PERMISSION`, so a Superadmin or a
Manager could later hand the page to anyone from the Assign Menu screen.

DB-backed screens are safe because the Oracle procedure re-checks the role
(`SP_SET_USER_STATUS`, `SP_CREATE_MANAGER_BY_SUPERADMIN`). A screen that acts on
**another** application over HTTP has no such procedure, so the role has to be
checked in the view as well:

```python
from functools import wraps

def superadmin_required(view_func):
    @wraps(view_func)
    def _wrapped_view(request, *args, **kwargs):
        role = (request.session.get('JB_RoleName') or '').strip().upper()
        if role not in ('SUPERADMIN',):
            messages.error(request, "Access Denied: This section is restricted to SuperAdmin.")
            return redirect('dashboard')
        return view_func(request, *args, **kwargs)
    return _wrapped_view


@permission_required_sp('disable_ejanata_user')   # 1. the menu grant
@superadmin_required                              # 2. and the role
def disable_ejanata_user(request, mobileno=''):
    ...
```

Order matters: `permission_required_sp` must be the **outer** decorator, so the
menu check runs first and a user with neither grant still gets the normal
"Access Denied" redirect. This is the pattern both SuperAdmin-only screens use
(`disable_ejanata_user`, `acc_statement`) — see
`database/JB_CALLCENTER_EJANATA_DISABLE_AND_ACC_STATEMENT.sql`.

---

## 7. Building a screen before its API exists

An endpoint path that is not known yet does not have to block the screen. Keep
the path in settings, empty by default (`EJANATA_DISABLE_USER_ENDPOINT`,
`EJANATA_ACC_STATEMENT_ENDPOINT`), and have the API method decide:

* **Read-only screens** can serve clearly labelled placeholder rows so the table
  can be finished and reviewed first. Mark them (`is_sample=True`) and say so
  above the table — a placeholder transaction that looks real is worse than no
  table at all. `Acc Statement` does this via `SAMPLE_TRANSACTIONS` in
  `login/api.py`; it disappears as soon as the real endpoint is set.
* **Screens that change data** must not fake a success. An unconfigured endpoint
  returns a clear "not configured" message instead of calling a guessed URL, so
  the button can never appear to have worked.

When the live response arrives, only the field mapping needs updating
(`API._normalize_statement_rows`). Keep it tolerant of casing — the eJanata
responses mix `mobileno` and `TxnDate` styles — and treat an unrecognised value
as unclassified rather than guessing.