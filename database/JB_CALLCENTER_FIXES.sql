
WHENEVER SQLERROR CONTINUE
/

CREATE OR REPLACE PROCEDURE SP_CREATE_MANAGER_BY_SUPERADMIN (
    p_superadmin_user_id IN NUMBER,
    p_fullname IN VARCHAR2,
    p_mobile IN VARCHAR2,
    p_email IN VARCHAR2,
    p_nid IN VARCHAR2,
    p_image_path IN VARCHAR2,
    p_temp_password IN VARCHAR2,
    p_gen_bank_id OUT VARCHAR2,
    p_success OUT NUMBER,
    p_msg OUT VARCHAR2
) AS
    v_role_id NUMBER;
    v_superadmin_role VARCHAR2(50);
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

    SELECT ROLE_ID INTO v_role_id FROM SYSTEM_ROLE WHERE UPPER(ROLE_NAME) = 'MANAGER';

    p_gen_bank_id := 'MGR' || SEQ_BANK_ID.NEXTVAL;

    INSERT INTO USERDETAIL (
        BANKID, FULLNAME, MOBILE_NO, EMAIL, NID, IMAGE_PATH, USERPASSWORD,
        ROLE_ID, IS_FIRST_LOGIN, USERSTATUS, APPROVED_BY_USER_ID, APPROVED_AT
    ) VALUES (
        p_gen_bank_id, p_fullname, p_mobile, p_email, p_nid, p_image_path, p_temp_password,
        v_role_id, 1, 'Enabled', p_superadmin_user_id, CURRENT_TIMESTAMP
    );

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

CREATE OR REPLACE PROCEDURE SP_APPROVE_REGISTRATION (
    p_reg_id IN NUMBER,
    p_temp_password IN VARCHAR2,
    p_manager_user_id IN NUMBER,
    p_gen_bank_id OUT VARCHAR2,
    p_user_email OUT VARCHAR2,
    p_success OUT NUMBER,
    p_msg OUT VARCHAR2
) AS
    v_fullname VARCHAR2(100);
    v_mobile   VARCHAR2(20);
    v_email    VARCHAR2(100);
    v_nid      VARCHAR2(30);
    v_attach   VARCHAR2(255);
    v_user_role_id NUMBER;
    v_manager_role VARCHAR2(50);
BEGIN
    SELECT UPPER(r.ROLE_NAME) INTO v_manager_role
    FROM USERDETAIL u
    JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
    WHERE u.USERDETAILID = p_manager_user_id;

    IF v_manager_role NOT IN ('MANAGER', 'SUPERADMIN') THEN
        p_success := 0;
        p_msg     := 'Access Denied: Only Manager or Superadmin can approve users.';
        RETURN;
    END IF;

    SELECT ROLE_ID INTO v_user_role_id FROM SYSTEM_ROLE WHERE UPPER(ROLE_NAME) = 'USER';

    SELECT FULLNAME, MOBILE_NO, EMAIL, NID, ATTACHMENT_PATH
    INTO v_fullname, v_mobile, v_email, v_nid, v_attach
    FROM USER_REGISTRATION
    WHERE REGISTRATION_ID = p_reg_id AND STATUS = 'PENDING';

    p_gen_bank_id := 'JB' || SEQ_BANK_ID.NEXTVAL;
    p_user_email  := v_email;

    INSERT INTO USERDETAIL (
        BANKID, FULLNAME, MOBILE_NO, EMAIL, NID, ATTACHMENT_PATH,
        USERPASSWORD, ROLE_ID, IS_FIRST_LOGIN, USERSTATUS, FAILED_ATTEMPTS,
        APPROVED_BY_USER_ID, APPROVED_AT
    ) VALUES (
        p_gen_bank_id, v_fullname, v_mobile, v_email, v_nid, v_attach,
        p_temp_password, v_user_role_id, 1, 'Enabled', 0,
        p_manager_user_id, CURRENT_TIMESTAMP
    );

    UPDATE USER_REGISTRATION SET STATUS = 'APPROVED' WHERE REGISTRATION_ID = p_reg_id;

    p_success := 1;
    p_msg     := 'User approved successfully.';
    COMMIT;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        p_success := 0;
        p_msg     := 'Registration record or role definition missing.';
    WHEN OTHERS THEN
        p_success := 0;
        p_msg     := SQLERRM;
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
               r.ROLE_NAME,
               u.IMAGE_PATH,
               u.USERSTATUS,
               u.APPROVED_AT
        FROM   USERDETAIL u
        JOIN   SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
        WHERE  UPPER(u.USERSTATUS) = 'ENABLED'
          AND  UPPER(r.ROLE_NAME) <> 'SUPERADMIN'
        ORDER  BY u.APPROVED_AT DESC NULLS LAST, u.FULLNAME;
END;
/

DECLARE
    v_mid NUMBER;
BEGIN
    BEGIN
        SELECT MENU_ID INTO v_mid FROM SYSTEM_MENU WHERE URL_NAME = 'raise_ticket';
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            INSERT INTO SYSTEM_MENU (MENU_TITLE, URL_NAME, PARENT_ID, ICON_CLASS, DISPLAY_ORDER)
            VALUES ('Raise Ticket', 'raise_ticket', NULL, 'bi-plus-circle', 7)
            RETURNING MENU_ID INTO v_mid;
    END;

    BEGIN
        SELECT MENU_ID INTO v_mid FROM SYSTEM_MENU WHERE URL_NAME = 'tickets';
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            INSERT INTO SYSTEM_MENU (MENU_TITLE, URL_NAME, PARENT_ID, ICON_CLASS, DISPLAY_ORDER)
            VALUES ('Tickets', 'tickets', NULL, 'bi-ticket-perforated', 8)
            RETURNING MENU_ID INTO v_mid;
    END;

    INSERT INTO ROLE_MENU_PERMISSION (ROLE_ID, MENU_ID)
        SELECT 1, MENU_ID FROM SYSTEM_MENU m
        WHERE NOT EXISTS (SELECT 1 FROM ROLE_MENU_PERMISSION rmp
                           WHERE rmp.ROLE_ID = 1 AND rmp.MENU_ID = m.MENU_ID);

    INSERT INTO ROLE_MENU_PERMISSION (ROLE_ID, MENU_ID)
        SELECT 2, MENU_ID FROM SYSTEM_MENU m
        WHERE m.URL_NAME IN ('dashboard','manager_dashboard','pending_registration',
                             'audit_trail','change_password','raise_ticket','tickets')
          AND NOT EXISTS (SELECT 1 FROM ROLE_MENU_PERMISSION rmp
                           WHERE rmp.ROLE_ID = 2 AND rmp.MENU_ID = m.MENU_ID);

    INSERT INTO ROLE_MENU_PERMISSION (ROLE_ID, MENU_ID)
        SELECT 3, MENU_ID FROM SYSTEM_MENU m
        WHERE m.URL_NAME IN ('dashboard','change_password','raise_ticket','tickets')
          AND NOT EXISTS (SELECT 1 FROM ROLE_MENU_PERMISSION rmp
                           WHERE rmp.ROLE_ID = 3 AND rmp.MENU_ID = m.MENU_ID);

    COMMIT;
END;
/

