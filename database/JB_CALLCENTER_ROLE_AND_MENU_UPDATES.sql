
WHENEVER SQLERROR CONTINUE
/

DECLARE
    v_mgr_mid NUMBER;
    v_mid     NUMBER;
BEGIN
    BEGIN
        SELECT MENU_ID INTO v_mgr_mid FROM SYSTEM_MENU WHERE URL_NAME = 'manager_dashboard';
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            INSERT INTO SYSTEM_MENU (MENU_TITLE, URL_NAME, PARENT_ID, ICON_CLASS, DISPLAY_ORDER)
            VALUES ('Manager Dashboard', 'manager_dashboard', NULL, 'bi-person-gear', 2)
            RETURNING MENU_ID INTO v_mgr_mid;
    END;

    BEGIN
        SELECT MENU_ID INTO v_mid FROM SYSTEM_MENU WHERE URL_NAME = 'user_unlock';
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            INSERT INTO SYSTEM_MENU (MENU_TITLE, URL_NAME, PARENT_ID, ICON_CLASS, DISPLAY_ORDER)
            VALUES ('User Unlock', 'user_unlock', NULL, 'bi-unlock', 9)
            RETURNING MENU_ID INTO v_mid;
    END;

    BEGIN
        SELECT MENU_ID INTO v_mid FROM SYSTEM_MENU WHERE URL_NAME = 'assign_role';
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            INSERT INTO SYSTEM_MENU (MENU_TITLE, URL_NAME, PARENT_ID, ICON_CLASS, DISPLAY_ORDER)
            VALUES ('Assign Role', 'assign_role', NULL, 'bi-person-badge', 10)
            RETURNING MENU_ID INTO v_mid;
    END;

    BEGIN
        SELECT MENU_ID INTO v_mid FROM SYSTEM_MENU WHERE URL_NAME = 'approve_user';
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            INSERT INTO SYSTEM_MENU (MENU_TITLE, URL_NAME, PARENT_ID, ICON_CLASS, DISPLAY_ORDER)
            VALUES ('Approve User Action', 'approve_user', v_mgr_mid, NULL, 2)
            RETURNING MENU_ID INTO v_mid;
    END;

    BEGIN
        SELECT MENU_ID INTO v_mid FROM SYSTEM_MENU WHERE URL_NAME = 'unlock_user';
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            INSERT INTO SYSTEM_MENU (MENU_TITLE, URL_NAME, PARENT_ID, ICON_CLASS, DISPLAY_ORDER)
            VALUES ('Unlock User Action', 'unlock_user', v_mgr_mid, NULL, 2)
            RETURNING MENU_ID INTO v_mid;
    END;

    INSERT INTO ROLE_MENU_PERMISSION (ROLE_ID, MENU_ID)
        SELECT 1, m.MENU_ID FROM SYSTEM_MENU m
        WHERE NOT EXISTS (SELECT 1 FROM ROLE_MENU_PERMISSION rmp
                          WHERE rmp.ROLE_ID = 1 AND rmp.MENU_ID = m.MENU_ID);

    INSERT INTO ROLE_MENU_PERMISSION (ROLE_ID, MENU_ID)
        SELECT 2, m.MENU_ID FROM SYSTEM_MENU m
        WHERE m.URL_NAME IN ('dashboard','manager_dashboard','pending_registration',
                             'audit_trail','change_password','raise_ticket','tickets',
                             'user_unlock','assign_role','approve_user','unlock_user')
          AND NOT EXISTS (SELECT 1 FROM ROLE_MENU_PERMISSION rmp
                          WHERE rmp.ROLE_ID = 2 AND rmp.MENU_ID = m.MENU_ID);

    INSERT INTO ROLE_MENU_PERMISSION (ROLE_ID, MENU_ID)
        SELECT 3, m.MENU_ID FROM SYSTEM_MENU m
        WHERE m.URL_NAME IN ('dashboard','change_password','raise_ticket','tickets')
          AND NOT EXISTS (SELECT 1 FROM ROLE_MENU_PERMISSION rmp
                          WHERE rmp.ROLE_ID = 3 AND rmp.MENU_ID = m.MENU_ID);

    COMMIT;
END;
/

DELETE FROM ROLE_MENU_PERMISSION
 WHERE ROLE_ID = 3
   AND MENU_ID IN (SELECT MENU_ID FROM SYSTEM_MENU
                    WHERE URL_NAME IN ('assign_role','user_unlock',
                                       'approve_user','unlock_user',
                                       'manager_dashboard','pending_registration',
                                       'audit_trail','create_manager'));
COMMIT;

CREATE OR REPLACE PROCEDURE SP_GET_ROLES (
    o_cursor OUT SYS_REFCURSOR
) AS
BEGIN
    OPEN o_cursor FOR
        SELECT ROLE_ID, ROLE_NAME, DESCRIPTION
        FROM   SYSTEM_ROLE
        ORDER  BY ROLE_ID;
END;
/

CREATE OR REPLACE PROCEDURE SP_GET_USERS_FOR_ROLE_ASSIGN (
    p_actor_user_id IN NUMBER,
    o_cursor        OUT SYS_REFCURSOR
) AS
    v_actor_role VARCHAR2(50);
BEGIN
    SELECT UPPER(r.ROLE_NAME)
      INTO v_actor_role
      FROM USERDETAIL u
      JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
     WHERE u.USERDETAILID = p_actor_user_id;

    IF v_actor_role = 'SUPERADMIN' THEN
        OPEN o_cursor FOR
            SELECT u.BANKID,
                   u.FULLNAME,
                   u.EMAIL,
                   u.USERSTATUS,
                   u.ROLE_ID,
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
                   u.ROLE_ID,
                   NVL(r.ROLE_NAME, 'No Role')
              FROM USERDETAIL u
              LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
             WHERE UPPER(NVL(r.ROLE_NAME, '')) <> 'SUPERADMIN'
             ORDER BY u.FULLNAME;
    ELSE
        OPEN o_cursor FOR
            SELECT CAST(NULL AS VARCHAR2(30)),
                   CAST(NULL AS VARCHAR2(100)),
                   CAST(NULL AS VARCHAR2(100)),
                   CAST(NULL AS VARCHAR2(20)),
                   CAST(NULL AS NUMBER),
                   CAST(NULL AS VARCHAR2(50))
              FROM DUAL
             WHERE 1 = 0;
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        OPEN o_cursor FOR
            SELECT CAST(NULL AS VARCHAR2(30)),
                   CAST(NULL AS VARCHAR2(100)),
                   CAST(NULL AS VARCHAR2(100)),
                   CAST(NULL AS VARCHAR2(20)),
                   CAST(NULL AS NUMBER),
                   CAST(NULL AS VARCHAR2(50))
              FROM DUAL
             WHERE 1 = 0;
END;
/

CREATE OR REPLACE PROCEDURE SP_ASSIGN_USER_ROLE (
    p_actor_user_id IN NUMBER,
    p_target_bank_id IN VARCHAR2,
    p_role_id IN NUMBER,
    p_success OUT NUMBER,
    p_msg OUT VARCHAR2
) AS
    v_actor_role   VARCHAR2(50);
    v_target_role  VARCHAR2(50) := '';
    v_target_id    NUMBER;
    v_new_role_name VARCHAR2(50) := NULL;
BEGIN
    p_success := 0;

    SELECT UPPER(r.ROLE_NAME)
      INTO v_actor_role
      FROM USERDETAIL u
      JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
     WHERE u.USERDETAILID = p_actor_user_id;

    IF v_actor_role NOT IN ('SUPERADMIN', 'MANAGER') THEN
        p_msg := 'Access Denied: Only Superadmin or Manager can assign roles.';
        RETURN;
    END IF;

    BEGIN
        SELECT u.USERDETAILID, UPPER(NVL(r.ROLE_NAME, ''))
          INTO v_target_id, v_target_role
          FROM USERDETAIL u
          LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
         WHERE u.BANKID = p_target_bank_id;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            p_msg := 'Target user not found.';
            RETURN;
    END;

    IF v_target_id = p_actor_user_id THEN
        p_msg := 'You cannot change your own role.';
        RETURN;
    END IF;

    IF p_role_id IS NOT NULL THEN
        BEGIN
            SELECT ROLE_NAME INTO v_new_role_name
              FROM SYSTEM_ROLE
             WHERE ROLE_ID = p_role_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                p_msg := 'Selected role does not exist.';
                RETURN;
        END;
    END IF;

    IF v_actor_role = 'MANAGER' THEN
        IF v_target_role IN ('SUPERADMIN', 'MANAGER') THEN
            p_msg := 'Access Denied: Managers can only assign roles to regular users.';
            RETURN;
        END IF;
        IF v_new_role_name IS NOT NULL AND UPPER(v_new_role_name) = 'SUPERADMIN' THEN
            p_msg := 'Access Denied: Only Superadmin can assign the Superadmin role.';
            RETURN;
        END IF;
    END IF;

    UPDATE USERDETAIL
       SET ROLE_ID = p_role_id
     WHERE USERDETAILID = v_target_id;

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

CREATE OR REPLACE PROCEDURE SP_GET_USER_DETAILS (
    p_user_id     IN  NUMBER,
    o_fullname    OUT VARCHAR2,
    o_email       OUT VARCHAR2,
    o_image_path  OUT VARCHAR2,
    o_role_name   OUT VARCHAR2,
    o_success     OUT NUMBER
) AS
BEGIN
    o_fullname   := NULL;
    o_email      := NULL;
    o_image_path := NULL;
    o_role_name  := NULL;
    o_success    := 0;

    SELECT u.FULLNAME, u.EMAIL, u.IMAGE_PATH, NVL(r.ROLE_NAME, 'No Role')
      INTO o_fullname, o_email, o_image_path, o_role_name
      FROM USERDETAIL u
      LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
     WHERE u.USERDETAILID = p_user_id;

    o_success := 1;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        o_success := 0;
    WHEN OTHERS THEN
        o_success := 0;
END;
/

CREATE OR REPLACE PROCEDURE SP_GET_ACTIVE_USERS (
    p_out_cursor OUT SYS_REFCURSOR
) AS
BEGIN
    OPEN p_out_cursor FOR
        SELECT u.BANKID,
               u.FULLNAME,
               u.MOBILE_NO,
               u.EMAIL,
               NVL(r.ROLE_NAME, 'No Role'),
               u.IMAGE_PATH,
               u.USERSTATUS,
               u.APPROVED_AT
          FROM   USERDETAIL u
          LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
         WHERE  UPPER(u.USERSTATUS) = 'ENABLED'
           AND  UPPER(NVL(r.ROLE_NAME, '')) <> 'SUPERADMIN'
         ORDER  BY u.APPROVED_AT DESC NULLS LAST, u.FULLNAME;
END;
/

