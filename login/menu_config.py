"""Menus that grant a permission but have no page of their own.

`acc_statement` is a JSON lookup endpoint behind the "Account Statement"
option shown inside the User Information panel of the User Unlock and Disable
eJanata User screens. It must stay a row in `SYSTEM_MENU` (so it is listed by
`SP_GET_ASSIGNABLE_MENUS` and can be granted from the Assign Menu screen), but
it is not a navigable page, so the sidebar must not render a link for it.
"""

HIDDEN_SIDEBAR_MENUS = frozenset({'acc_statement'})
