
WHENEVER SQLERROR CONTINUE
/

DECLARE
    v_id NUMBER;
BEGIN
    BEGIN
        SELECT MENU_ID INTO v_id FROM SYSTEM_MENU WHERE URL_NAME = 'user_unlock';
    EXCEPTION WHEN NO_DATA_FOUND THEN
        INSERT INTO SYSTEM_MENU (MENU_TITLE, URL_NAME, PARENT_ID, ICON_CLASS, DISPLAY_ORDER)
        VALUES ('User Unlock', 'user_unlock', NULL, 'bi-unlock', 9);
    END;

    BEGIN
        SELECT MENU_ID INTO v_id FROM SYSTEM_MENU WHERE URL_NAME = 'disable_enable';
    EXCEPTION WHEN NO_DATA_FOUND THEN
        INSERT INTO SYSTEM_MENU (MENU_TITLE, URL_NAME, PARENT_ID, ICON_CLASS, DISPLAY_ORDER)
        VALUES ('Disable/Enable', 'disable_enable', NULL, 'bi-toggle2-on', 11);
    END;
    COMMIT;
END;
/

DECLARE
    v_menu_id NUMBER;
BEGIN
    FOR v_url IN (SELECT 'user_unlock' AS u FROM DUAL
                  UNION ALL SELECT 'disable_enable' FROM DUAL) LOOP
        SELECT MENU_ID INTO v_menu_id FROM SYSTEM_MENU WHERE URL_NAME = v_url.u;

        FOR r IN (SELECT ROLE_ID FROM SYSTEM_ROLE
                   WHERE UPPER(ROLE_NAME) IN ('SUPERADMIN', 'MANAGER')) LOOP
            INSERT INTO ROLE_MENU_PERMISSION (ROLE_ID, MENU_ID)
            SELECT r.ROLE_ID, v_menu_id FROM DUAL
             WHERE NOT EXISTS (SELECT 1 FROM ROLE_MENU_PERMISSION x
                                WHERE x.ROLE_ID = r.ROLE_ID AND x.MENU_ID = v_menu_id);
        END LOOP;

        INSERT INTO USER_MENU_ASSIGNMENT (USERDETAILID, MENU_ID, ASSIGNED_BY_USER_ID, ASSIGNED_AT)
        SELECT u.USERDETAILID, v_menu_id, NULL, CURRENT_TIMESTAMP
          FROM USERDETAIL u
          JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
         WHERE UPPER(NVL(r.ROLE_NAME, '')) IN ('SUPERADMIN', 'MANAGER')
           AND NOT EXISTS (SELECT 1 FROM USER_MENU_ASSIGNMENT a
                            WHERE a.USERDETAILID = u.USERDETAILID
                              AND a.MENU_ID = v_menu_id);
    END LOOP;
    COMMIT;
END;
/

CREATE OR REPLACE PROCEDURE SP_GET_USER_MENUS (
    p_user_detail_id IN  NUMBER,
    p_menu_cursor    OUT SYS_REFCURSOR
) AS
BEGIN
    OPEN p_menu_cursor FOR
        SELECT m.MENU_ID, m.MENU_TITLE, m.URL_NAME, m.PARENT_ID,
               m.ICON_CLASS, m.DISPLAY_ORDER
          FROM SYSTEM_MENU m
         WHERE EXISTS (SELECT 1
                         FROM USER_MENU_ASSIGNMENT uma
                        WHERE uma.USERDETAILID = p_user_detail_id
                          AND uma.MENU_ID = m.MENU_ID)
            OR (NOT EXISTS (SELECT 1
                              FROM USER_MENU_ASSIGNMENT any_uma
                             WHERE any_uma.USERDETAILID = p_user_detail_id)
            AND EXISTS (SELECT 1
                          FROM USERDETAIL u
                          JOIN ROLE_MENU_PERMISSION rmp ON rmp.ROLE_ID = u.ROLE_ID
                         WHERE u.USERDETAILID = p_user_detail_id
                           AND rmp.MENU_ID = m.MENU_ID))
      ORDER BY m.PARENT_ID NULLS FIRST, m.DISPLAY_ORDER ASC, m.MENU_ID;
END;
/

CREATE OR REPLACE PROCEDURE SP_CHECK_USER_MENU_ACCESS (
    p_user_detail_id IN NUMBER,
    p_url_name       IN VARCHAR2,
    p_has_access     OUT NUMBER
) AS
    v_count NUMBER := 0;
BEGIN

    SELECT COUNT(1) INTO v_count
      FROM SYSTEM_MENU m
     WHERE UPPER(TRIM(m.URL_NAME)) = UPPER(TRIM(p_url_name))
       AND ( EXISTS (SELECT 1
                       FROM USER_MENU_ASSIGNMENT uma
                      WHERE uma.USERDETAILID = p_user_detail_id
                        AND uma.MENU_ID = m.MENU_ID)
             OR (NOT EXISTS (SELECT 1
                               FROM USER_MENU_ASSIGNMENT any_uma
                              WHERE any_uma.USERDETAILID = p_user_detail_id)
             AND EXISTS (SELECT 1
                           FROM USERDETAIL u
                           JOIN ROLE_MENU_PERMISSION rmp ON rmp.ROLE_ID = u.ROLE_ID
                          WHERE u.USERDETAILID = p_user_detail_id
                            AND rmp.MENU_ID = m.MENU_ID)) );

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

CREATE OR REPLACE PROCEDURE SP_GET_ASSIGNABLE_MENUS (
    p_actor_user_id IN NUMBER,
    o_cursor        OUT SYS_REFCURSOR
) AS
BEGIN
    OPEN o_cursor FOR
        SELECT m.MENU_ID, m.MENU_TITLE, m.URL_NAME, NVL(m.ICON_CLASS, '')
          FROM SYSTEM_MENU m
         WHERE m.PARENT_ID IS NULL
           AND ( EXISTS (SELECT 1
                           FROM USER_MENU_ASSIGNMENT uma
                          WHERE uma.USERDETAILID = p_actor_user_id
                            AND uma.MENU_ID = m.MENU_ID)
                 OR (NOT EXISTS (SELECT 1
                                   FROM USER_MENU_ASSIGNMENT any_uma
                                  WHERE any_uma.USERDETAILID = p_actor_user_id)
                 AND EXISTS (SELECT 1
                               FROM USERDETAIL u
                               JOIN ROLE_MENU_PERMISSION rmp ON rmp.ROLE_ID = u.ROLE_ID
                              WHERE u.USERDETAILID = p_actor_user_id
                                AND rmp.MENU_ID = m.MENU_ID)) )
      ORDER BY m.DISPLAY_ORDER, m.MENU_TITLE;
END;
/

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
        p_msg := 'Access Denied: Managers can only assign menus to regular users.';
        RETURN;
    END IF;

    BEGIN
        SELECT MENU_TITLE INTO v_menu_title
          FROM SYSTEM_MENU
         WHERE MENU_ID = p_menu_id;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            p_msg := 'Menu not found.';
            RETURN;
    END;

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

    SELECT COUNT(1) INTO v_cnt
      FROM USER_MENU_ASSIGNMENT
     WHERE USERDETAILID = v_target_id AND MENU_ID = p_menu_id;

    IF p_enable = 1 THEN
        IF v_cnt > 0 THEN
            p_success := 1;
            p_msg     := 'Menu "' || v_menu_title || '" is already assigned to ' || p_target_userid || '.';
            RETURN;
        END IF;
        INSERT INTO USER_MENU_ASSIGNMENT (USERDETAILID, MENU_ID, ASSIGNED_BY_USER_ID, ASSIGNED_AT)
        VALUES (v_target_id, p_menu_id, p_actor_user_id, CURRENT_TIMESTAMP);
        p_msg := 'Menu "' || v_menu_title || '" assigned to ' || p_target_userid || '.';
    ELSE
        IF v_cnt = 0 THEN
            p_success := 1;
            p_msg     := 'Menu "' || v_menu_title || '" is not assigned to ' || p_target_userid || '.';
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

CREATE OR REPLACE PROCEDURE SP_REGISTER_FAILED_LOGIN (
    p_user_detail_id  IN  NUMBER,
    p_max_attempts    IN  NUMBER,
    o_attempts        OUT NUMBER,
    o_disabled        OUT NUMBER,
    o_status          OUT VARCHAR2
) AS
    v_attempts NUMBER := 0;
    v_status   VARCHAR2(20) := 'Enabled';
BEGIN
    o_attempts := 0;
    o_disabled := 0;
    o_status   := NULL;

    SELECT NVL(FAILED_ATTEMPTS, 0), NVL(USERSTATUS, 'Enabled')
      INTO v_attempts, v_status
      FROM USERDETAIL
     WHERE USERDETAILID = p_user_detail_id;

    v_attempts := v_attempts + 1;
    o_attempts := v_attempts;

    UPDATE USERDETAIL
       SET FAILED_ATTEMPTS = v_attempts
     WHERE USERDETAILID = p_user_detail_id;

    IF v_attempts >= NVL(p_max_attempts, 3)
       AND UPPER(TRIM(v_status)) = 'ENABLED' THEN
        UPDATE USERDETAIL
           SET USERSTATUS = 'Disabled'
         WHERE USERDETAILID = p_user_detail_id;
        o_disabled := 1;
        o_status   := 'Disabled';
    ELSE
        o_status := v_status;
    END IF;

    COMMIT;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        o_attempts := 0;
        o_status   := NULL;
    WHEN OTHERS THEN
        o_attempts := 0;
        o_status   := NULL;
END;
/

CREATE OR REPLACE PROCEDURE SP_RESET_FAILED_LOGIN (
    p_user_detail_id IN NUMBER
) AS
BEGIN
    UPDATE USERDETAIL
       SET FAILED_ATTEMPTS = 0
     WHERE USERDETAILID = p_user_detail_id;
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        NULL;
END;
/

CREATE OR REPLACE PROCEDURE SP_SET_USER_STATUS (
    p_actor_user_detail_id  IN NUMBER,
    p_target_user_detail_id IN NUMBER,
    p_status                IN VARCHAR2,
    p_remarks               IN VARCHAR2,
    o_userid                OUT VARCHAR2,
    p_success               OUT NUMBER,
    p_msg                   OUT VARCHAR2
) AS
    v_actor_role  VARCHAR2(50);
    v_target_role VARCHAR2(50) := '';
    v_userid      VARCHAR2(30);
    v_new_status  VARCHAR2(20);
BEGIN
    p_success := 0;
    o_userid  := NULL;

    v_new_status := UPPER(TRIM(NVL(p_status, 'ENABLED')));
    IF v_new_status NOT IN ('ENABLED', 'DISABLED', 'LOCKED') THEN
        p_msg := 'Invalid status: ' || p_status;
        RETURN;
    END IF;

    SELECT UPPER(NVL(r.ROLE_NAME, '')) INTO v_actor_role
      FROM USERDETAIL u
      LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
     WHERE u.USERDETAILID = p_actor_user_detail_id;

    IF v_actor_role NOT IN ('SUPERADMIN', 'MANAGER') THEN
        p_msg := 'Access Denied: Only a Superadmin or a Manager can enable or disable an account.';
        RETURN;
    END IF;

    BEGIN
        SELECT u.USERID, UPPER(NVL(r.ROLE_NAME, ''))
          INTO v_userid, v_target_role
          FROM USERDETAIL u
          LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
         WHERE u.USERDETAILID = p_target_user_detail_id;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            p_msg := 'Target user not found.';
            RETURN;
    END;

    o_userid := v_userid;

    IF p_actor_user_detail_id = p_target_user_detail_id THEN
        p_msg := 'You cannot change the status of your own account.';
        RETURN;
    END IF;

    IF v_actor_role = 'MANAGER' AND v_target_role <> 'USER' THEN
        p_msg := 'Access Denied: a Manager can only enable or disable a regular User account. '
              || 'Ask a Superadmin to handle ' || v_userid || '.';
        RETURN;
    END IF;

    IF v_new_status = 'ENABLED' THEN
        UPDATE USERDETAIL
           SET USERSTATUS      = 'Enabled',
               FAILED_ATTEMPTS = 0
         WHERE USERDETAILID = p_target_user_detail_id;
        p_msg := v_userid || ' has been enabled.';
    ELSE
        UPDATE USERDETAIL
           SET USERSTATUS = INITCAP(v_new_status)
         WHERE USERDETAILID = p_target_user_detail_id;
        p_msg := v_userid || ' has been ' || LOWER(INITCAP(v_new_status)) || '.';
    END IF;

    p_success := 1;
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        p_success := 0;
        p_msg     := SQLERRM;
END;
/

CREATE OR REPLACE PROCEDURE SP_ENABLE_USER (
    p_actor_user_detail_id  IN NUMBER,
    p_target_user_detail_id IN NUMBER,
    p_remarks               IN VARCHAR2,
    p_success               OUT NUMBER,
    p_msg                   OUT VARCHAR2
) AS
    v_userid VARCHAR2(30);
BEGIN
    SP_SET_USER_STATUS(p_actor_user_detail_id, p_target_user_detail_id,
                       'Enabled', p_remarks, v_userid, p_success, p_msg);
END;
/

CREATE OR REPLACE PROCEDURE SP_UNLOCK_USER_BY_MOBILE (
    p_mobile               IN  VARCHAR2,
    p_temp_hashed_password IN  VARCHAR2,
    o_userid               OUT VARCHAR2,
    o_email                OUT VARCHAR2,
    o_status               OUT VARCHAR2,
    p_success              OUT NUMBER,
    p_msg                  OUT VARCHAR2
) AS
    v_user_detail_id NUMBER;
BEGIN
    p_success := 0;
    o_userid  := NULL;
    o_email   := NULL;
    o_status  := NULL;

    IF TRIM(NVL(p_mobile, ' ')) IS NULL THEN
        p_msg := 'Mobile number is required.';
        RETURN;
    END IF;

    SELECT USERDETAILID INTO v_user_detail_id
      FROM (SELECT USERDETAILID
              FROM USERDETAIL
             WHERE TRIM(MOBILE_NO) = TRIM(p_mobile)
             ORDER BY USERDETAILID DESC)
     WHERE ROWNUM = 1;

    SELECT USERID, EMAIL INTO o_userid, o_email
      FROM USERDETAIL
     WHERE USERDETAILID = v_user_detail_id;

    IF p_temp_hashed_password IS NULL THEN
        UPDATE USERDETAIL
           SET USERSTATUS      = 'Enabled',
               FAILED_ATTEMPTS = 0
         WHERE USERDETAILID = v_user_detail_id;
    ELSE
        UPDATE USERDETAIL
           SET USERPASSWORD    = p_temp_hashed_password,
               USERSTATUS      = 'Enabled',
               IS_FIRST_LOGIN  = 1,
               FAILED_ATTEMPTS = 0
         WHERE USERDETAILID = v_user_detail_id;
    END IF;

    SELECT USERSTATUS INTO o_status
      FROM USERDETAIL
     WHERE USERDETAILID = v_user_detail_id;

    p_success := 1;
    p_msg     := o_userid || ' has been unlocked.';
    COMMIT;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        p_success := 0;
        p_msg     := 'No user found with the provided mobile number.';
    WHEN OTHERS THEN
        p_success := 0;
        p_msg     := SQLERRM;
END;
/

CREATE OR REPLACE PROCEDURE SP_CREATE_MANAGER_BY_SUPERADMIN (
    p_superadmin_user_id IN  NUMBER,
    p_fullname            IN  VARCHAR2,
    p_mobile              IN  VARCHAR2,
    p_email               IN  VARCHAR2,
    p_nid                 IN  VARCHAR2,
    p_image_path          IN  VARCHAR2,
    p_temp_password       IN  VARCHAR2,
    o_userid              OUT VARCHAR2,
    p_success             OUT NUMBER,
    p_msg                 OUT VARCHAR2
) AS
    v_role_id           NUMBER;
    v_superadmin_role   VARCHAR2(50);
    v_new_user_id       NUMBER;
BEGIN
    SELECT UPPER(r.ROLE_NAME) INTO v_superadmin_role
      FROM USERDETAIL u
      JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
     WHERE u.USERDETAILID = p_superadmin_user_id;

    IF v_superadmin_role != 'SUPERADMIN' THEN
        p_success := 0;
        p_msg     := 'Access Denied: Only Superadmin can create Manager accounts.';
        RETURN;
    END IF;

    SELECT ROLE_ID INTO v_role_id
      FROM SYSTEM_ROLE
     WHERE UPPER(ROLE_NAME) = 'MANAGER';

    o_userid := 'MGR' || FN_GET_NEXT_ID('MANAGER_USER_SEQ');

    INSERT INTO USERDETAIL (
        USERID, FULLNAME, MOBILE_NO, EMAIL, NID, IMAGE_PATH, USERPASSWORD,
        ROLE_ID, IS_FIRST_LOGIN, USERSTATUS, APPROVED_BY_USER_ID, APPROVED_AT
    ) VALUES (
        o_userid, p_fullname, p_mobile, p_email, p_nid, p_image_path, p_temp_password,
        v_role_id, 1, 'Enabled', p_superadmin_user_id, CURRENT_TIMESTAMP
    ) RETURNING USERDETAILID INTO v_new_user_id;

    FOR mc IN (
        SELECT MENU_ID FROM SYSTEM_MENU
         WHERE URL_NAME IN (
            'dashboard', 'manager_dashboard', 'pending_registration',
            'user_unlock', 'assign_menu', 'approve_user', 'unlock_user',
            'disable_enable',
            'audit_trail', 'change_password', 'raise_ticket', 'tickets'
         )
    ) LOOP
        INSERT INTO USER_MENU_ASSIGNMENT
            (USERDETAILID, MENU_ID, ASSIGNED_BY_USER_ID, ASSIGNED_AT)
        VALUES
            (v_new_user_id, mc.MENU_ID, p_superadmin_user_id, CURRENT_TIMESTAMP);
    END LOOP;

    p_success := 1;
    p_msg     := 'Manager account created successfully.';
    COMMIT;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        p_success := 0;
        p_msg     := 'Superadmin or Manager role definition missing.';
    WHEN OTHERS THEN
        p_success := 0;
        p_msg     := SQLERRM;
END;
/

COMMIT;

