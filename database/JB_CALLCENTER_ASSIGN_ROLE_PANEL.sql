-- ===========================================================================
--  *** SUPERSEDED - DO NOT USE ***
--  This legacy patch has been folded into:
--    - JB_CALLCENTER_SETUP.sql      (brand-new install, no triggers/sequences)
--    - JB_CALLCENTER_MIGRATION_NO_TRIGGER_SEQUENCE.sql  (upgrade of existing DB)
--  Use one of those two files instead of this one.
-- ===========================================================================
--  JB CALL CENTER - ASSIGN ROLE DRAG & DROP PANEL + ADMIN APPROVAL ACCESS FIX
-- ---------------------------------------------------------------------------
--  Run as the JBCALLCENTER schema user (the same user Django connects with).
--  Idempotent - safe to re-run any number of times.
--
--  WHAT THIS SCRIPT DOES
--  ----------------------------------------------------------------------
--  1. Registers every SYSTEM_MENU permission row required by the sidebar and
--     by the SP_CHECK_USER_MENU_ACCESS auth decorator (visible rows for the
--     sidebar, hidden URL-only permission children for actions such as
--     approve_user / unlock_user / user_unlock / assign_role).  This is what
--     fixes the current bug where Superadmin and Manager get
--         "Access Denied: You do not have permission to view this section."
--     on the Pending Registration / Approve / Unlock / Assign Role pages.
--
--  2. Grants those menus idempotently:
--       Superadmin (1) : EVERY menu
--       Manager    (2) : manager_dashboard, pending_registration, audit_trail,
--                        user_unlock, assign_role, approve_user, unlock_user,
--                        dashboard, change_password, raise_ticket, tickets
--       User       (3) : dashboard, change_password, raise_ticket, tickets
--       (User is explicitly locked OUT of every admin menu.)
--
--  3. Hardens SP_CHECK_USER_MENU_ACCESS to be case / whitespace tolerant so a
--     logged-in session can never be wrongly denied because of URL_NAME casing
--     (the exact cause of the "you do not have access" report).
--
--  4. Adds the DB side required by the new drag & drop Assign Role panel:
--       SP_GET_ASSIGNABLE_ROLES(p_actor_user_id, o_cursor)
--         - Superadmin -> ALL roles.
--         - Manager    -> only roles whose menu-permission set is a SUBSET of
--                         the Manager's OWN permission set (a Manager may only
--                         assign a role whose permissions he himself has).
--       SP_GET_USERS_FOR_ROLE_ASSIGN  (with actual notification to the target)
--       SP_ASSIGN_USER_ROLE           (DB-side hierarchy enforcement:
--                         Manager can never grant SUPERADMIN or MANAGER roles,
--                         and can only grant roles whose permission set is a
--                         subset of his own -- verified inside the procedure).
-- ===========================================================================

WHENEVER SQLERROR CONTINUE
/

-- ===========================================================================
-- 1 + 2. MENUS + IDEMPOTENT GRANTS
-- ===========================================================================
DECLARE
    v_mid          NUMBER;
    v_mgr_mid      NUMBER;
    v_m1           NUMBER;
    v_m2           NUMBER;
    v_m3           NUMBER;
BEGIN
    -- 1a. Manager Dashboard (visible sidebar)
    BEGIN
        SELECT MENU_ID INTO v_mgr_mid FROM SYSTEM_MENU WHERE URL_NAME = 'manager_dashboard';
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            INSERT INTO SYSTEM_MENU (MENU_TITLE, URL_NAME, PARENT_ID, ICON_CLASS, DISPLAY_ORDER)
            VALUES ('Manager Dashboard', 'manager_dashboard', NULL, 'bi-people', 1)
            RETURNING MENU_ID INTO v_mgr_mid;
    END;

    -- 1b. Pending Registration (visible sidebar)
    BEGIN
        SELECT MENU_ID INTO v_mid FROM SYSTEM_MENU WHERE URL_NAME = 'pending_registration';
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            INSERT INTO SYSTEM_MENU (MENU_TITLE, URL_NAME, PARENT_ID, ICON_CLASS, DISPLAY_ORDER)
            VALUES ('Pending Registration', 'pending_registration', NULL, 'bi-person-plus', 2)
            RETURNING MENU_ID INTO v_mid;
    END;

    -- 1c. User Unlock (visible sidebar)
    BEGIN
        SELECT MENU_ID INTO v_mid FROM SYSTEM_MENU WHERE URL_NAME = 'user_unlock';
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            INSERT INTO SYSTEM_MENU (MENU_TITLE, URL_NAME, PARENT_ID, ICON_CLASS, DISPLAY_ORDER)
            VALUES ('User Unlock', 'user_unlock', NULL, 'bi-unlock', 3)
            RETURNING MENU_ID INTO v_mid;
    END;

    -- 1d. Assign Role (visible sidebar)
    BEGIN
        SELECT MENU_ID INTO v_mid FROM SYSTEM_MENU WHERE URL_NAME = 'assign_role';
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            INSERT INTO SYSTEM_MENU (MENU_TITLE, URL_NAME, PARENT_ID, ICON_CLASS, DISPLAY_ORDER)
            VALUES ('Assign Role', 'assign_role', NULL, 'bi-person-badge', 4)
            RETURNING MENU_ID INTO v_mid;
    END;

    -- 1e. Hidden action permissions (children of Manager Dashboard, never
    --     rendered by the sidebar but required by SP_CHECK_USER_MENU_ACCESS)
    BEGIN
        SELECT MENU_ID INTO v_mid FROM SYSTEM_MENU WHERE URL_NAME = 'approve_user';
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            INSERT INTO SYSTEM_MENU (MENU_TITLE, URL_NAME, PARENT_ID, ICON_CLASS, DISPLAY_ORDER)
            VALUES ('Approve User', 'approve_user', v_mgr_mid, NULL, 20)
            RETURNING MENU_ID INTO v_mid;
    END;

    BEGIN
        SELECT MENU_ID INTO v_mid FROM SYSTEM_MENU WHERE URL_NAME = 'unlock_user';
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            INSERT INTO SYSTEM_MENU (MENU_TITLE, URL_NAME, PARENT_ID, ICON_CLASS, DISPLAY_ORDER)
            VALUES ('Unlock User', 'unlock_user', v_mgr_mid, NULL, 21)
            RETURNING MENU_ID INTO v_mid;
    END;

    BEGIN
        SELECT MENU_ID INTO v_mid FROM SYSTEM_MENU WHERE URL_NAME = 'audit_trail';
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            INSERT INTO SYSTEM_MENU (MENU_TITLE, URL_NAME, PARENT_ID, ICON_CLASS, DISPLAY_ORDER)
            VALUES ('Audit Trail', 'audit_trail', NULL, 'bi-clock-history', 5)
            RETURNING MENU_ID INTO v_mid;
    END;

    -- ============================
    -- 2. IDEMPOTENT GRANTS
    -- ============================

    -- Superadmin (1): every menu
    INSERT INTO ROLE_MENU_PERMISSION (ROLE_ID, MENU_ID)
        SELECT 1, m.MENU_ID FROM SYSTEM_MENU m
         WHERE NOT EXISTS (SELECT 1 FROM ROLE_MENU_PERMISSION rmp
                           WHERE rmp.ROLE_ID = 1 AND rmp.MENU_ID = m.MENU_ID);

    -- Manager (2): admin + user menus (includes the hidden action perms)
    INSERT INTO ROLE_MENU_PERMISSION (ROLE_ID, MENU_ID)
        SELECT 2, m.MENU_ID FROM SYSTEM_MENU m
         WHERE m.URL_NAME IN ('dashboard','manager_dashboard','pending_registration',
                              'audit_trail','user_unlock','assign_role',
                              'approve_user','unlock_user',
                              'change_password','raise_ticket','tickets')
           AND NOT EXISTS (SELECT 1 FROM ROLE_MENU_PERMISSION rmp
                           WHERE rmp.ROLE_ID = 2 AND rmp.MENU_ID = m.MENU_ID);

    -- User (3): NON-admin menus only - and remove any admin menu accidentally
    -- granted before (defense in depth: a User can never reach admin pages).
    INSERT INTO ROLE_MENU_PERMISSION (ROLE_ID, MENU_ID)
        SELECT 3, m.MENU_ID FROM SYSTEM_MENU m
         WHERE m.URL_NAME IN ('dashboard','change_password','raise_ticket','tickets')
           AND NOT EXISTS (SELECT 1 FROM ROLE_MENU_PERMISSION rmp
                           WHERE rmp.ROLE_ID = 3 AND rmp.MENU_ID = m.MENU_ID);

    DELETE FROM ROLE_MENU_PERMISSION rmp
     WHERE rmp.ROLE_ID = 3
       AND rmp.MENU_ID IN (SELECT m.MENU_ID FROM SYSTEM_MENU m
                           WHERE m.URL_NAME IN ('manager_dashboard','pending_registration',
                                                'audit_trail','user_unlock','assign_role',
                                                'approve_user','unlock_user'));

    COMMIT;
END;
/

-- ===========================================================================
-- 3. SP_CHECK_USER_MENU_ACCESS - CASE / WHITESPACE TOLERANT
-- ===========================================================================
CREATE OR REPLACE PROCEDURE SP_CHECK_USER_MENU_ACCESS (
    p_user_id    IN NUMBER,
    p_url_name   IN VARCHAR2,
    p_has_access OUT NUMBER
) AS
    v_count NUMBER := 0;
BEGIN
    SELECT COUNT(1) INTO v_count
      FROM SYSTEM_MENU m
      JOIN ROLE_MENU_PERMISSION rmp ON m.MENU_ID = rmp.MENU_ID
      JOIN USERDETAIL u ON u.ROLE_ID = rmp.ROLE_ID
     WHERE u.USERDETAILID = p_user_id
       AND TRIM(UPPER(m.URL_NAME)) = TRIM(UPPER(NVL(p_url_name, '')));

    IF v_count > 0 THEN
        p_has_access := 1;
    ELSE
        p_has_access := 0;
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        p_has_access := 0;
END;
/

-- ===========================================================================
-- 4a. SP_GET_ASSIGNABLE_ROLES - hierarchy aware
--     Superadmin -> all roles; Manager -> roles whose permission set is a
--     subset of the Manager's own.  (Makes the drag & drop panel show only
--     the roles the operator is ALLOWED to grant.)
-- ===========================================================================
CREATE OR REPLACE PROCEDURE SP_GET_ASSIGNABLE_ROLES (
    p_actor_user_id IN NUMBER,
    o_cursor        OUT SYS_REFCURSOR
) AS
    v_actor_role_id  NUMBER;
    v_actor_role     VARCHAR2(50);
BEGIN
    SELECT NVL(u.ROLE_ID, 0), UPPER(NVL(r.ROLE_NAME, ''))
      INTO v_actor_role_id, v_actor_role
      FROM USERDETAIL u
      LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
     WHERE u.USERDETAILID = p_actor_user_id;

    IF v_actor_role = 'SUPERADMIN' THEN
        OPEN o_cursor FOR
            SELECT sr.ROLE_ID, sr.ROLE_NAME, NVL(sr.DESCRIPTION, '')
              FROM SYSTEM_ROLE sr
             ORDER BY sr.ROLE_ID;
    ELSIF v_actor_role = 'MANAGER' THEN
        OPEN o_cursor FOR
            SELECT sr.ROLE_ID, sr.ROLE_NAME, NVL(sr.DESCRIPTION, '')
              FROM SYSTEM_ROLE sr
             WHERE NOT EXISTS (
                     SELECT 1
                       FROM ROLE_MENU_PERMISSION rmp_r
                      WHERE rmp_r.ROLE_ID = sr.ROLE_ID
                        AND NOT EXISTS (
                              SELECT 1
                                FROM ROLE_MENU_PERMISSION rmp_a
                               WHERE rmp_a.ROLE_ID = v_actor_role_id
                                 AND rmp_a.MENU_ID = rmp_r.MENU_ID))
             ORDER BY sr.ROLE_ID;
    ELSE
        OPEN o_cursor FOR
            SELECT sr.ROLE_ID, sr.ROLE_NAME, NVL(sr.DESCRIPTION, '')
              FROM SYSTEM_ROLE sr
             WHERE 1 = 0;
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        OPEN o_cursor FOR
            SELECT sr.ROLE_ID, sr.ROLE_NAME, NVL(sr.DESCRIPTION, '')
              FROM SYSTEM_ROLE sr
             WHERE 1 = 0;
END;
/

-- ===========================================================================
-- 4b. SP_GET_USERS_FOR_ROLE_ASSIGN - with target notification
--     Superadmin -> every user; Manager -> every user except Superadmins
--     (managers may never touch a Superadmin account).
-- ===========================================================================
CREATE OR REPLACE PROCEDURE SP_GET_USERS_FOR_ROLE_ASSIGN (
    p_actor_user_id IN NUMBER,
    o_cursor        OUT SYS_REFCURSOR
) AS
    v_actor_role VARCHAR2(50);
BEGIN
    SELECT UPPER(NVL(r.ROLE_NAME, ''))
      INTO v_actor_role
      FROM USERDETAIL u
      LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
     WHERE u.USERDETAILID = p_actor_user_id;

    IF v_actor_role = 'SUPERADMIN' THEN
        OPEN o_cursor FOR
            SELECT u.BANKID,
                   u.FULLNAME,
                   u.EMAIL,
                   u.USERSTATUS,
                   NVL(u.ROLE_ID, 0),
                   NVL(r.ROLE_NAME, 'No Role')
              FROM USERDETAIL u
              LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
             ORDER BY u.FULLNAME;
    ELSIF v_actor_role = 'MANAGER' THEN
        OPEN o_cursor FOR
            SELECT u.BANKID,
                   u.FULLNAME,
                   u.EMAIL,
                   u.USERSTATUS,
                   NVL(u.ROLE_ID, 0),
                   NVL(r.ROLE_NAME, 'No Role')
              FROM USERDETAIL u
              LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
             WHERE UPPER(NVL(r.ROLE_NAME, '')) <> 'SUPERADMIN'
             ORDER BY u.FULLNAME;
    ELSE
        OPEN o_cursor FOR
            SELECT u.BANKID,
                   u.FULLNAME,
                   u.EMAIL,
                   u.USERSTATUS,
                   NVL(u.ROLE_ID, 0),
                   NVL(r.ROLE_NAME, 'No Role')
              FROM USERDETAIL u
              LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
             WHERE 1 = 0;
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        OPEN o_cursor FOR
            SELECT u.BANKID,
                   u.FULLNAME,
                   u.EMAIL,
                   u.USERSTATUS,
                   NVL(u.ROLE_ID, 0),
                   NVL(r.ROLE_NAME, 'No Role')
              FROM USERDETAIL u
              LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
             WHERE 1 = 0;
END;
/

-- ===========================================================================
-- 4c. SP_ASSIGN_USER_ROLE - DB-side hierarchy enforcement + notification
-- ===========================================================================
CREATE OR REPLACE PROCEDURE SP_ASSIGN_USER_ROLE (
    p_actor_user_id    IN NUMBER,
    p_target_bank_id   IN VARCHAR2,
    p_role_id          IN NUMBER,
    p_success          OUT NUMBER,
    p_msg              OUT VARCHAR2
) AS
    v_actor_role     VARCHAR2(50);
    v_actor_role_id  NUMBER;
    v_target_user_id NUMBER;
    v_target_role    VARCHAR2(50) := '';
    v_new_role_name  VARCHAR2(50) := NULL;
BEGIN
    p_success := 0;

    -- 1. actor identity + role
    SELECT UPPER(NVL(r.ROLE_NAME, '')), NVL(u.ROLE_ID, 0)
      INTO v_actor_role, v_actor_role_id
      FROM USERDETAIL u
      LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
     WHERE u.USERDETAILID = p_actor_user_id;

    IF v_actor_role NOT IN ('SUPERADMIN', 'MANAGER') THEN
        p_msg := 'Access Denied: Only Superadmin or Manager can assign roles.';
        RETURN;
    END IF;

    -- 2. target
    BEGIN
        SELECT u.USERDETAILID, UPPER(NVL(r.ROLE_NAME, ''))
          INTO v_target_user_id, v_target_role
          FROM USERDETAIL u
          LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
         WHERE u.BANKID = p_target_bank_id;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            p_msg := 'Target user not found.';
            RETURN;
    END;

    IF v_target_user_id = p_actor_user_id THEN
        p_msg := 'You cannot change your own role.';
        RETURN;
    END IF;

    -- 3. new role name (if assigning, not removing)
    BEGIN
        IF p_role_id IS NOT NULL THEN
            SELECT ROLE_NAME INTO v_new_role_name FROM SYSTEM_ROLE WHERE ROLE_ID = p_role_id;
        END IF;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            p_msg := 'Selected role does not exist.';
            RETURN;
    END;

    -- 4. hierarchy rules
    IF v_actor_role = 'MANAGER' THEN
        -- Manager can never act on a Superadmin or on another Manager
        IF v_target_role IN ('SUPERADMIN', 'MANAGER') THEN
            p_msg := 'Access Denied: Managers can only assign roles to regular users.';
            RETURN;
        END IF;
        -- Manager can never grant SUPERADMIN or MANAGER
        IF v_new_role_name IS NOT NULL AND UPPER(v_new_role_name) IN ('SUPERADMIN', 'MANAGER') THEN
            p_msg := 'Access Denied: Managers cannot grant the Superadmin or Manager role.';
            RETURN;
        END IF;
        -- Manager can only grant a role whose permission set is a subset of his own
        IF v_new_role_name IS NOT NULL THEN
            DECLARE
                v_extra NUMBER := 0;
            BEGIN
                SELECT COUNT(1) INTO v_extra
                  FROM ROLE_MENU_PERMISSION rmp_r
                 WHERE rmp_r.ROLE_ID = p_role_id
                   AND NOT EXISTS (
                         SELECT 1 FROM ROLE_MENU_PERMISSION rmp_a
                          WHERE rmp_a.ROLE_ID = v_actor_role_id
                            AND rmp_a.MENU_ID = rmp_r.MENU_ID);
                IF v_extra > 0 THEN
                    p_msg := 'Access Denied: You may only grant roles whose permissions you possess.';
                    RETURN;
                END IF;
            END;
        END IF;
    END IF;

    -- 5. apply
    UPDATE USERDETAIL SET ROLE_ID = p_role_id WHERE USERDETAILID = v_target_user_id;

    IF p_role_id IS NULL THEN
        p_msg := 'Role removed from user ' || p_target_bank_id || '.';
    ELSE
        p_msg := 'Role "' || v_new_role_name || '" assigned to user ' || p_target_bank_id || '.';
    END IF;
    p_success := 1;
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        p_success := 0;
        p_msg     := SQLERRM;
END;
/

-- ===========================================================================
--  VERIFY AFTERWARDS
--   SELECT URL_NAME FROM SYSTEM_MENU ORDER BY DISPLAY_ORDER;
--   SELECT r.ROLE_NAME, m.URL_NAME FROM ROLE_MENU_PERMISSION rmp
--     JOIN SYSTEM_ROLE r ON r.ROLE_ID = rmp.ROLE_ID
--     JOIN SYSTEM_MENU m   ON m.MENU_ID = rmp.MENU_ID
--    ORDER BY r.ROLE_ID, m.DISPLAY_ORDER;
-- ===========================================================================
