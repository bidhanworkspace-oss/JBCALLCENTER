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
| API integration   | **Your** custom API class/method (e.g. `API().GetUserByMobileNo(mobileno)`) — see below |

> Your API work is NOT done here. The view below shows where the `API()` class is
> *called*; you write the class and its methods yourself. The `user_unlock` page is
> already converted to this flow — it reads `mobileno` (POST/GET or the `<str:mobileno>`
> path arg) and calls `api.GetUserByMobileNo(mobileno)`, `api.GetUserStatus()`, and on
> POST `api.UpdateUserStatus(...)`. Create `login/api.py` with an `API` class exposing
> those methods (plus `GetUserStatusByStatusName`), and for the manager's one-click
> unlock add `UnlockUserByBankID(bank_id, hashed_temp_pwd)` returning
> `{'success': bool, 'user_email': str, 'msg': str}`. Until the class exists, those
> pages show a friendly message with the import error instead of crashing.

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

## 5. Reference — how the existing User Unlock is wired

| Concern      | Procedure / URL / view                                       |
|--------------|--------------------------------------------------------------|
| Search       | same view, reads `mobileno` (`request.POST`/`GET`/path) → `api.GetUserByMobileNo(mobileno)` |
| Action       | same view, POST `btnupdateuser` → `api.GetUserStatusByStatusName(...)` + `api.UpdateUserStatus(...)` |
| Page view    | `login.views.user_unlock` → `templates/login/user_unlock.html` |
| URLs         | `/user-unlock/` and `/user-unlock/<str:mobileno>/`           |
| Permissions  | `SYSTEM_MENU.URL_NAME = 'user_unlock'` via `ROLE_MENU_PERMISSION`/`USER_MENU_ASSIGNMENT` |

If your new page reuses the unlock/manage action, add its own `SYSTEM_MENU` child
rows (e.g. `manage_user_lookup`) and decorate its views — same as the table above.