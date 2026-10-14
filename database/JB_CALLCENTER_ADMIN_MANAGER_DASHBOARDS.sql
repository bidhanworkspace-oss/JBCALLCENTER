-- ============================================================================
-- JB Call Center - ADMIN / MANAGER DASHBOARDS + BANK SUPPORT FIX
-- Schema: run while connected to the LIVE schema  CALLCENTERAPPSY
-- (TOAD: connect as CALLCENTERAPPSY, open this file, Execute as script, COMMIT)
--
-- What this file does:
--   1. SP_GET_MANAGERS ............ Manager list for the Super Admin Dashboard
--   2. SP_GET_ACTIVE_USERS ........ Manager Dashboard: only regular Users
--   3. SP_GET_LOCKED_USERS ........ Manager Dashboard: only regular Users
--   4. SP_GET_USERS_FOR_ADMIN ..... Super Admin Dashboard: User + Bank Support
--   5. SP_GET_MENU_ASSIGN_USERS ... Assign Menu screen (USERID based)
--   6. SP_SET_USER_MENU_ACCESS .... Assign Menu screen (USERID based)
--   7. SP_ASSIGN_BANK_SUPPORT_ROLE  Make/remove Bank Support AND grant/revoke
--                                   the ticket menus so the Bank Support user
--                                   can actually open Tickets and respond.
--   8. SYSTEM_MENU "Admin Dashboard" + menu grants for Super Admin/Manager
--
-- Safe to run more than once.
-- ============================================================================

SET DEFINE OFF
WHENEVER SQLERROR CONTINUE

-- ----------------------------------------------------------------------------
-- 1. Super Admin Dashboard - list of Managers
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_GET_MANAGERS (
    p_out_cursor OUT SYS_REFCURSOR
) AS
BEGIN
    OPEN p_out_cursor FOR
        SELECT u.USERDETAILID, u.USERID, u.FULLNAME, u.MOBILE_NO, u.EMAIL,
               u.USERSTATUS, u.FAILED_ATTEMPTS, u.IMAGE_PATH, u.APPROVED_AT
          FROM USERDETAIL u
          LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
         WHERE UPPER(NVL(r.ROLE_NAME, '')) = 'MANAGER'
         ORDER BY u.FULLNAME;
END;
/

-- ----------------------------------------------------------------------------
-- 2. Manager Dashboard - active users (regular Users only, no Managers)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_GET_ACTIVE_USERS (
    p_out_cursor OUT SYS_REFCURSOR
) AS
BEGIN
    OPEN p_out_cursor FOR
        SELECT u.USERID, u.FULLNAME, u.MOBILE_NO, u.EMAIL,
               NVL(r.ROLE_NAME, 'User'), u.IMAGE_PATH, u.USERSTATUS, u.APPROVED_AT
          FROM USERDETAIL u
          LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
         WHERE UPPER(u.USERSTATUS) = 'ENABLED'
           AND UPPER(NVL(r.ROLE_NAME, '')) = 'USER'
         ORDER BY u.APPROVED_AT DESC NULLS LAST, u.FULLNAME;
END;
/

-- ----------------------------------------------------------------------------
-- 3. Manager Dashboard - locked / disabled users (regular Users only)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_GET_LOCKED_USERS (
    p_out_cursor OUT SYS_REFCURSOR
) AS
BEGIN
    OPEN p_out_cursor FOR
        SELECT u.USERID, u.FULLNAME, u.EMAIL, u.USERSTATUS, u.FAILED_ATTEMPTS
          FROM USERDETAIL u
          LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
         WHERE UPPER(u.USERSTATUS) <> 'ENABLED'
           AND UPPER(NVL(r.ROLE_NAME, '')) = 'USER'
         ORDER BY u.USERDETAILID DESC;
END;
/

-- ----------------------------------------------------------------------------
-- 4. Super Admin Dashboard - every User and Bank Support account
--    (all statuses, so the Super Admin can enable AND disable)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_GET_USERS_FOR_ADMIN (
    p_out_cursor OUT SYS_REFCURSOR
) AS
BEGIN
    OPEN p_out_cursor FOR
        SELECT u.USERDETAILID, u.USERID, u.FULLNAME, u.MOBILE_NO, u.EMAIL,
               NVL(r.ROLE_NAME, 'User'), u.IMAGE_PATH, u.USERSTATUS, u.APPROVED_AT
          FROM USERDETAIL u
          LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
         WHERE UPPER(NVL(r.ROLE_NAME, '')) IN ('USER', 'BANK SUPPORT')
         ORDER BY u.FULLNAME;
END;
/

-- ----------------------------------------------------------------------------
-- 5. Assign Menu screen - users the actor may manage (USERID based)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_GET_MENU_ASSIGN_USERS (
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
            SELECT u.USERID,
                   u.USERDETAILID,
                   u.FULLNAME,
                   u.EMAIL,
                   u.USERSTATUS,
                   NVL(r.ROLE_NAME, 'No Role'),
                   NVL(u.ROLE_ID, 0),
                   (SELECT LISTAGG(m2.MENU_ID, ',') WITHIN GROUP (ORDER BY m2.DISPLAY_ORDER, m2.MENU_ID)
                      FROM USER_MENU_ASSIGNMENT a
                      JOIN SYSTEM_MENU m2 ON a.MENU_ID = m2.MENU_ID
                     WHERE a.USERDETAILID = u.USERDETAILID
                       AND m2.PARENT_ID IS NULL) AS MENU_IDS,
                   (SELECT LISTAGG(m2.MENU_TITLE, '|') WITHIN GROUP (ORDER BY m2.DISPLAY_ORDER, m2.MENU_ID)
                      FROM USER_MENU_ASSIGNMENT a
                      JOIN SYSTEM_MENU m2 ON a.MENU_ID = m2.MENU_ID
                     WHERE a.USERDETAILID = u.USERDETAILID
                       AND m2.PARENT_ID IS NULL) AS MENU_TITLES
              FROM USERDETAIL u
              LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
             WHERE u.USERDETAILID <> p_actor_user_id
             ORDER BY u.FULLNAME;
    ELSIF v_actor_role = 'MANAGER' THEN
        OPEN o_cursor FOR
            SELECT u.USERID,
                   u.USERDETAILID,
                   u.FULLNAME,
                   u.EMAIL,
                   u.USERSTATUS,
                   NVL(r.ROLE_NAME, 'No Role'),
                   NVL(u.ROLE_ID, 0),
                   (SELECT LISTAGG(m2.MENU_ID, ',') WITHIN GROUP (ORDER BY m2.DISPLAY_ORDER, m2.MENU_ID)
                      FROM USER_MENU_ASSIGNMENT a
                      JOIN SYSTEM_MENU m2 ON a.MENU_ID = m2.MENU_ID
                     WHERE a.USERDETAILID = u.USERDETAILID
                       AND m2.PARENT_ID IS NULL) AS MENU_IDS,
                   (SELECT LISTAGG(m2.MENU_TITLE, '|') WITHIN GROUP (ORDER BY m2.DISPLAY_ORDER, m2.MENU_ID)
                      FROM USER_MENU_ASSIGNMENT a
                      JOIN SYSTEM_MENU m2 ON a.MENU_ID = m2.MENU_ID
                     WHERE a.USERDETAILID = u.USERDETAILID
                       AND m2.PARENT_ID IS NULL) AS MENU_TITLES
              FROM USERDETAIL u
              LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
             WHERE UPPER(NVL(r.ROLE_NAME, '')) = 'USER'
             ORDER BY u.FULLNAME;
    ELSE
        OPEN o_cursor FOR
            SELECT CAST(NULL AS VARCHAR2(30)), CAST(NULL AS NUMBER),
                   CAST(NULL AS VARCHAR2(100)), CAST(NULL AS VARCHAR2(100)),
                   CAST(NULL AS VARCHAR2(20)), CAST(NULL AS VARCHAR2(50)),
                   CAST(NULL AS NUMBER), CAST(NULL AS VARCHAR2(4000)),
                   CAST(NULL AS VARCHAR2(4000))
              FROM DUAL WHERE 1 = 0;
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        OPEN o_cursor FOR
            SELECT CAST(NULL AS VARCHAR2(30)), CAST(NULL AS NUMBER),
                   CAST(NULL AS VARCHAR2(100)), CAST(NULL AS VARCHAR2(100)),
                   CAST(NULL AS VARCHAR2(20)), CAST(NULL AS VARCHAR2(50)),
                   CAST(NULL AS NUMBER), CAST(NULL AS VARCHAR2(4000)),
                   CAST(NULL AS VARCHAR2(4000))
              FROM DUAL WHERE 1 = 0;
END;
/

-- ----------------------------------------------------------------------------
-- 6. Assign Menu screen - assign/remove one menu (USERID based)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_SET_USER_MENU_ACCESS (
    p_actor_user_id  IN NUMBER,
    p_target_userid  IN VARCHAR2,
    p_menu_id        IN NUMBER,
    p_enable         IN NUMBER,
    p_success        OUT NUMBER,
    p_msg            OUT VARCHAR2
) AS
    v_actor_role      VARCHAR2(50);
    v_target_id       NUMBER;
    v_target_role     VARCHAR2(50) := '';
    v_actor_per_user  NUMBER := 0;
    v_target_per_user NUMBER := 0;
    v_cnt             NUMBER;
    v_menu_title      VARCHAR2(100);
BEGIN
    p_success := 0;

    SELECT UPPER(NVL(r.ROLE_NAME, ''))
      INTO v_actor_role
      FROM USERDETAIL u
      LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
     WHERE u.USERDETAILID = p_actor_user_id;

    IF v_actor_role NOT IN ('SUPERADMIN', 'MANAGER') THEN
        p_msg := 'Access Denied: Only Superadmin or Manager can change menu access.';
        RETURN;
    END IF;

    BEGIN
        SELECT u.USERDETAILID, UPPER(NVL(r.ROLE_NAME, ''))
          INTO v_target_id, v_target_role
          FROM USERDETAIL u
          LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
         WHERE u.USERID = p_target_userid;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            p_msg := 'Target user not found.';
            RETURN;
    END;

    IF v_target_id = p_actor_user_id THEN
        p_msg := 'You cannot change your own menu access.';
        RETURN;
    END IF;

    IF v_actor_role = 'MANAGER' AND v_target_role <> 'USER' THEN
        p_msg := 'Access Denied: Managers can only assign menus to regular User accounts.';
        RETURN;
    END IF;

    SELECT MENU_TITLE INTO v_menu_title
      FROM SYSTEM_MENU
     WHERE MENU_ID = p_menu_id;

    SELECT COUNT(1) INTO v_actor_per_user
      FROM USER_MENU_ASSIGNMENT
     WHERE USERDETAILID = p_actor_user_id;

    IF v_actor_per_user > 0 THEN
        SELECT COUNT(1) INTO v_cnt
          FROM USER_MENU_ASSIGNMENT
         WHERE USERDETAILID = p_actor_user_id AND MENU_ID = p_menu_id;
    ELSE
        SELECT COUNT(1) INTO v_cnt
          FROM USERDETAIL u
          JOIN ROLE_MENU_PERMISSION rmp ON rmp.ROLE_ID = u.ROLE_ID
         WHERE u.USERDETAILID = p_actor_user_id
           AND rmp.MENU_ID = p_menu_id;
    END IF;

    IF v_cnt = 0 THEN
        p_msg := 'Access Denied: You may only grant menus that are assigned to you.';
        RETURN;
    END IF;

    SELECT COUNT(1) INTO v_target_per_user
      FROM USER_MENU_ASSIGNMENT
     WHERE USERDETAILID = v_target_id;

    IF v_target_per_user = 0 THEN
        INSERT INTO USER_MENU_ASSIGNMENT (USERDETAILID, MENU_ID, ASSIGNED_BY_USER_ID, ASSIGNED_AT)
        SELECT v_target_id, rmp.MENU_ID, p_actor_user_id, CURRENT_TIMESTAMP
          FROM USERDETAIL u
          JOIN ROLE_MENU_PERMISSION rmp ON rmp.ROLE_ID = u.ROLE_ID
         WHERE u.USERDETAILID = v_target_id;
    END IF;

    SELECT COUNT(1) INTO v_cnt
      FROM USER_MENU_ASSIGNMENT
     WHERE USERDETAILID = v_target_id AND MENU_ID = p_menu_id;

    IF p_enable = 1 THEN
        IF v_cnt > 0 THEN
            p_msg := 'Menu already assigned to the user.';
            RETURN;
        END IF;
        INSERT INTO USER_MENU_ASSIGNMENT (USERDETAILID, MENU_ID, ASSIGNED_BY_USER_ID, ASSIGNED_AT)
        VALUES (v_target_id, p_menu_id, p_actor_user_id, CURRENT_TIMESTAMP);
        p_msg := 'Menu "' || v_menu_title || '" assigned to ' || p_target_userid || '.';
    ELSE
        IF v_cnt = 0 THEN
            p_msg := 'Menu is not assigned to the user.';
            RETURN;
        END IF;
        DELETE FROM USER_MENU_ASSIGNMENT
         WHERE USERDETAILID = v_target_id AND MENU_ID = p_menu_id;
        p_msg := 'Menu "' || v_menu_title || '" removed from ' || p_target_userid || '.';
    END IF;

    p_success := 1;
    COMMIT;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        p_success := 0;
        p_msg     := 'Menu not found.';
    WHEN OTHERS THEN
        p_success := 0;
        p_msg     := SQLERRM;
END;
/

-- ----------------------------------------------------------------------------
-- 7. Assign/remove Bank Support role AND grant/revoke the ticket menus
--    Accepts either the USERID or the BANKID for the target user.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_ASSIGN_BANK_SUPPORT_ROLE (
    p_actor_user_id  IN NUMBER,
    p_target_userid  IN VARCHAR2,
    p_enable         IN NUMBER,
    p_success        OUT NUMBER,
    p_msg            OUT VARCHAR2
) AS
    v_actor_role      VARCHAR2(50);
    v_target_id       NUMBER;
    v_target_role     VARCHAR2(50) := '';
    v_support_role_id NUMBER;
    v_user_role_id    NUMBER;
BEGIN
    p_success := 0;

    SELECT UPPER(NVL(r.ROLE_NAME, '')) INTO v_actor_role
      FROM USERDETAIL u
      LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
     WHERE u.USERDETAILID = p_actor_user_id;

    IF v_actor_role <> 'SUPERADMIN' THEN
        p_msg := 'Access Denied: Only Superadmin can assign the Bank Support role.';
        RETURN;
    END IF;

    BEGIN
        SELECT u.USERDETAILID, UPPER(NVL(r.ROLE_NAME, ''))
          INTO v_target_id, v_target_role
          FROM USERDETAIL u
          LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
         WHERE u.USERID = p_target_userid;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            p_msg := 'Target user not found.';
            RETURN;
    END;

    IF v_target_id = p_actor_user_id THEN
        p_msg := 'You cannot change your own role.';
        RETURN;
    END IF;

    SELECT ROLE_ID INTO v_support_role_id FROM SYSTEM_ROLE WHERE UPPER(ROLE_NAME) = 'BANK SUPPORT';
    SELECT ROLE_ID INTO v_user_role_id    FROM SYSTEM_ROLE WHERE UPPER(ROLE_NAME) = 'USER';

    IF p_enable = 1 THEN
        IF v_target_role NOT IN ('USER', 'BANK SUPPORT') THEN
            p_msg := 'Only regular users can be made Bank Support.';
            RETURN;
        END IF;
        UPDATE USERDETAIL SET ROLE_ID = v_support_role_id WHERE USERDETAILID = v_target_id;

        -- Grant the menus a Bank Support user needs (per-user rows win over
        -- role menus in SP_GET_USER_MENUS).
        INSERT INTO USER_MENU_ASSIGNMENT (USERDETAILID, MENU_ID, ASSIGNED_BY_USER_ID, ASSIGNED_AT)
        SELECT v_target_id, m.MENU_ID, p_actor_user_id, CURRENT_TIMESTAMP
          FROM SYSTEM_MENU m
         WHERE m.URL_NAME IN ('dashboard','tickets','raise_ticket','change_password')
           AND NOT EXISTS (SELECT 1 FROM USER_MENU_ASSIGNMENT a
                            WHERE a.USERDETAILID = v_target_id AND a.MENU_ID = m.MENU_ID);

        p_msg := 'User ' || p_target_userid || ' is now Bank Support.';
    ELSE
        IF v_target_role <> 'BANK SUPPORT' THEN
            p_msg := 'User is not Bank Support.';
            RETURN;
        END IF;
        UPDATE USERDETAIL SET ROLE_ID = v_user_role_id WHERE USERDETAILID = v_target_id;
        p_msg := 'Bank Support role removed from ' || p_target_userid || '.';
    END IF;

    p_success := 1;
    COMMIT;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        p_success := 0;
        p_msg     := 'Role definition (BANK SUPPORT / USER) is missing.';
    WHEN OTHERS THEN
        p_success := 0;
        p_msg     := SQLERRM;
END;
/

-- ----------------------------------------------------------------------------
-- 8. Menus: "Admin Dashboard" (Super Admin) and role/per-user grants
-- ----------------------------------------------------------------------------

-- Make sure the "Admin Dashboard" menu exists as a visible sidebar item.
DECLARE
    v_mid NUMBER;
BEGIN
    BEGIN
        SELECT MENU_ID INTO v_mid FROM SYSTEM_MENU WHERE URL_NAME = 'admin_dashboard';
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            INSERT INTO SYSTEM_MENU (MENU_TITLE, URL_NAME, PARENT_ID, ICON_CLASS, DISPLAY_ORDER)
            VALUES ('Admin Dashboard', 'admin_dashboard', NULL, 'bi-shield-lock', 2)
            RETURNING MENU_ID INTO v_mid;
    END;
    COMMIT;
END;
/

-- Role grants: Superadmin gets everything; Manager gets the manager screens.
DECLARE
BEGIN
    -- Superadmin (all menus)
    INSERT INTO ROLE_MENU_PERMISSION (ROLE_ID, MENU_ID)
    SELECT r.ROLE_ID, m.MENU_ID
      FROM SYSTEM_ROLE r, SYSTEM_MENU m
     WHERE UPPER(TRIM(r.ROLE_NAME)) = 'SUPERADMIN'
       AND NOT EXISTS (SELECT 1 FROM ROLE_MENU_PERMISSION x
                        WHERE x.ROLE_ID = r.ROLE_ID AND x.MENU_ID = m.MENU_ID);

    -- Manager
    INSERT INTO ROLE_MENU_PERMISSION (ROLE_ID, MENU_ID)
    SELECT r.ROLE_ID, m.MENU_ID
      FROM SYSTEM_ROLE r, SYSTEM_MENU m
     WHERE UPPER(TRIM(r.ROLE_NAME)) = 'MANAGER'
       AND m.URL_NAME IN ('dashboard','manager_dashboard','pending_registration',
                          'user_unlock','disable_enable','assign_menu',
                          'approve_user','unlock_user','audit_trail',
                          'change_password','raise_ticket','tickets')
       AND NOT EXISTS (SELECT 1 FROM ROLE_MENU_PERMISSION x
                        WHERE x.ROLE_ID = r.ROLE_ID AND x.MENU_ID = m.MENU_ID);

    -- Bank Support
    INSERT INTO ROLE_MENU_PERMISSION (ROLE_ID, MENU_ID)
    SELECT r.ROLE_ID, m.MENU_ID
      FROM SYSTEM_ROLE r, SYSTEM_MENU m
     WHERE UPPER(TRIM(r.ROLE_NAME)) = 'BANK SUPPORT'
       AND m.URL_NAME IN ('dashboard','tickets','raise_ticket','change_password')
       AND NOT EXISTS (SELECT 1 FROM ROLE_MENU_PERMISSION x
                        WHERE x.ROLE_ID = r.ROLE_ID AND x.MENU_ID = m.MENU_ID);

    COMMIT;
END;
/

-- Per-user grants: Superadmin and Manager must actually HAVE the menus in
-- USER_MENU_ASSIGNMENT (that is what SP_GET_USER_MENUS / the sidebar read).
DECLARE
BEGIN
    -- Superadmin: every menu
    INSERT INTO USER_MENU_ASSIGNMENT (USERDETAILID, MENU_ID, ASSIGNED_BY_USER_ID, ASSIGNED_AT)
    SELECT u.USERDETAILID, m.MENU_ID, NULL, CURRENT_TIMESTAMP
      FROM USERDETAIL u
      JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
     CROSS JOIN SYSTEM_MENU m
     WHERE UPPER(TRIM(r.ROLE_NAME)) = 'SUPERADMIN'
       AND NOT EXISTS (SELECT 1 FROM USER_MENU_ASSIGNMENT a
                        WHERE a.USERDETAILID = u.USERDETAILID AND a.MENU_ID = m.MENU_ID);

    -- Manager: manager screens
    INSERT INTO USER_MENU_ASSIGNMENT (USERDETAILID, MENU_ID, ASSIGNED_BY_USER_ID, ASSIGNED_AT)
    SELECT u.USERDETAILID, m.MENU_ID, NULL, CURRENT_TIMESTAMP
      FROM USERDETAIL u
      JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
     CROSS JOIN SYSTEM_MENU m
     WHERE UPPER(TRIM(r.ROLE_NAME)) = 'MANAGER'
       AND m.URL_NAME IN ('dashboard','manager_dashboard','pending_registration',
                          'user_unlock','disable_enable','assign_menu',
                          'approve_user','unlock_user','audit_trail',
                          'change_password','raise_ticket','tickets')
       AND NOT EXISTS (SELECT 1 FROM USER_MENU_ASSIGNMENT a
                        WHERE a.USERDETAILID = u.USERDETAILID AND a.MENU_ID = m.MENU_ID);

    COMMIT;
END;
/

COMMIT;
