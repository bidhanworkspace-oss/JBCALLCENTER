
WHENEVER SQLERROR CONTINUE
/

DECLARE
    v_mid          NUMBER;
    v_mgr_mid      NUMBER;
    v_m1           NUMBER;
    v_m2           NUMBER;
    v_m3           NUMBER;
BEGIN

    BEGIN
        SELECT MENU_ID INTO v_mgr_mid FROM SYSTEM_MENU WHERE URL_NAME = 'manager_dashboard';
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            INSERT INTO SYSTEM_MENU (MENU_TITLE, URL_NAME, PARENT_ID, ICON_CLASS, DISPLAY_ORDER)
            VALUES ('Manager Dashboard', 'manager_dashboard', NULL, 'bi-people', 1)
            RETURNING MENU_ID INTO v_mgr_mid;
    END;

    BEGIN
        SELECT MENU_ID INTO v_mid FROM SYSTEM_MENU WHERE URL_NAME = 'pending_registration';
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            INSERT INTO SYSTEM_MENU (MENU_TITLE, URL_NAME, PARENT_ID, ICON_CLASS, DISPLAY_ORDER)
            VALUES ('Pending Registration', 'pending_registration', NULL, 'bi-person-plus', 2)
            RETURNING MENU_ID INTO v_mid;
    END;

    BEGIN
        SELECT MENU_ID INTO v_mid FROM SYSTEM_MENU WHERE URL_NAME = 'user_unlock';
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            INSERT INTO SYSTEM_MENU (MENU_TITLE, URL_NAME, PARENT_ID, ICON_CLASS, DISPLAY_ORDER)
            VALUES ('User Unlock', 'user_unlock', NULL, 'bi-unlock', 3)
            RETURNING MENU_ID INTO v_mid;
    END;

    BEGIN
        SELECT MENU_ID INTO v_mid FROM SYSTEM_MENU WHERE URL_NAME = 'assign_role';
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            INSERT INTO SYSTEM_MENU (MENU_TITLE, URL_NAME, PARENT_ID, ICON_CLASS, DISPLAY_ORDER)
            VALUES ('Assign Role', 'assign_role', NULL, 'bi-person-badge', 4)
            RETURNING MENU_ID INTO v_mid;
    END;

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

    INSERT INTO ROLE_MENU_PERMISSION (ROLE_ID, MENU_ID)
        SELECT 1, m.MENU_ID FROM SYSTEM_MENU m
         WHERE NOT EXISTS (SELECT 1 FROM ROLE_MENU_PERMISSION rmp
                           WHERE rmp.ROLE_ID = 1 AND rmp.MENU_ID = m.MENU_ID);

    INSERT INTO ROLE_MENU_PERMISSION (ROLE_ID, MENU_ID)
        SELECT 2, m.MENU_ID FROM SYSTEM_MENU m
         WHERE m.URL_NAME IN ('dashboard','manager_dashboard','pending_registration',
                              'audit_trail','user_unlock','assign_role',
                              'approve_user','unlock_user',
                              'change_password','raise_ticket','tickets')
           AND NOT EXISTS (SELECT 1 FROM ROLE_MENU_PERMISSION rmp
                           WHERE rmp.ROLE_ID = 2 AND rmp.MENU_ID = m.MENU_ID);

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

    SELECT UPPER(NVL(r.ROLE_NAME, '')), NVL(u.ROLE_ID, 0)
      INTO v_actor_role, v_actor_role_id
      FROM USERDETAIL u
      LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
     WHERE u.USERDETAILID = p_actor_user_id;

    IF v_actor_role NOT IN ('SUPERADMIN', 'MANAGER') THEN
        p_msg := 'Access Denied: Only Superadmin or Manager can assign roles.';
        RETURN;
    END IF;

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

    BEGIN
        IF p_role_id IS NOT NULL THEN
            SELECT ROLE_NAME INTO v_new_role_name FROM SYSTEM_ROLE WHERE ROLE_ID = p_role_id;
        END IF;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            p_msg := 'Selected role does not exist.';
            RETURN;
    END;

    IF v_actor_role = 'MANAGER' THEN

        IF v_target_role IN ('SUPERADMIN', 'MANAGER') THEN
            p_msg := 'Access Denied: Managers can only assign roles to regular users.';
            RETURN;
        END IF;

        IF v_new_role_name IS NOT NULL AND UPPER(v_new_role_name) IN ('SUPERADMIN', 'MANAGER') THEN
            p_msg := 'Access Denied: Managers cannot grant the Superadmin or Manager role.';
            RETURN;
        END IF;

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

