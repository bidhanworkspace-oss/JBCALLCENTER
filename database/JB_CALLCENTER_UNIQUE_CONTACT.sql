WHENEVER SQLERROR EXIT SQL.SQLCODE
/

DECLARE
    v_cnt NUMBER;
BEGIN
    UPDATE USERDETAIL u
       SET u.EMAIL = LOWER(u.USERID) || '@jbcallcenter.local'
     WHERE EXISTS (SELECT 1
                     FROM USERDETAIL d
                    WHERE LOWER(TRIM(d.EMAIL)) = LOWER(TRIM(u.EMAIL))
                      AND d.USERDETAILID < u.USERDETAILID);

    UPDATE USER_REGISTRATION r
       SET r.EMAIL = 'user' || r.REGISTRATION_ID || '@jbcallcenter.local'
     WHERE EXISTS (SELECT 1
                     FROM USER_REGISTRATION d
                    WHERE LOWER(TRIM(d.EMAIL)) = LOWER(TRIM(r.EMAIL))
                      AND d.REGISTRATION_ID < r.REGISTRATION_ID);

    SELECT COUNT(1) INTO v_cnt
      FROM (SELECT TRIM(MOBILE_NO) AS MOBILE_NO
              FROM USERDETAIL
             WHERE MOBILE_NO IS NOT NULL
             GROUP BY TRIM(MOBILE_NO)
            HAVING COUNT(*) > 1);
    IF v_cnt > 0 THEN
        RAISE_APPLICATION_ERROR(-20001, 'USERDETAIL still has duplicate mobile numbers.');
    END IF;

    SELECT COUNT(1) INTO v_cnt
      FROM (SELECT TRIM(MOBILE_NO) AS MOBILE_NO
              FROM USER_REGISTRATION
             WHERE MOBILE_NO IS NOT NULL
             GROUP BY TRIM(MOBILE_NO)
            HAVING COUNT(*) > 1);
    IF v_cnt > 0 THEN
        RAISE_APPLICATION_ERROR(-20002, 'USER_REGISTRATION still has duplicate mobile numbers.');
    END IF;

    SELECT COUNT(1) INTO v_cnt
      FROM (SELECT LOWER(TRIM(EMAIL)) AS EMAIL_LC
              FROM USERDETAIL
             WHERE EMAIL IS NOT NULL
             GROUP BY LOWER(TRIM(EMAIL))
            HAVING COUNT(*) > 1);
    IF v_cnt > 0 THEN
        RAISE_APPLICATION_ERROR(-20003, 'USERDETAIL still has duplicate email addresses.');
    END IF;

    SELECT COUNT(1) INTO v_cnt
      FROM (SELECT LOWER(TRIM(EMAIL)) AS EMAIL_LC
              FROM USER_REGISTRATION
             WHERE EMAIL IS NOT NULL
             GROUP BY LOWER(TRIM(EMAIL))
            HAVING COUNT(*) > 1);
    IF v_cnt > 0 THEN
        RAISE_APPLICATION_ERROR(-20004, 'USER_REGISTRATION still has duplicate email addresses.');
    END IF;

    COMMIT;
END;
/

DECLARE
    PROCEDURE make_not_null(
        p_table IN VARCHAR2,
        p_col   IN VARCHAR2
    ) IS
    BEGIN
        EXECUTE IMMEDIATE 'ALTER TABLE ' || p_table || ' MODIFY (' || p_col || ' NOT NULL)';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE != -1442 THEN
                RAISE;
            END IF;
    END;
BEGIN
    make_not_null('USERDETAIL', 'EMAIL');
    make_not_null('USERDETAIL', 'MOBILE_NO');
    make_not_null('USER_REGISTRATION', 'EMAIL');
    make_not_null('USER_REGISTRATION', 'MOBILE_NO');
    COMMIT;
END;
/

DECLARE
    PROCEDURE add_column(
        p_table IN VARCHAR2,
        p_col   IN VARCHAR2,
        p_type  IN VARCHAR2
    ) IS
    BEGIN
        EXECUTE IMMEDIATE 'ALTER TABLE ' || p_table || ' ADD (' || p_col || ' ' || p_type || ')';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE != -1430 THEN
                RAISE;
            END IF;
    END;
BEGIN
    add_column('USER_REGISTRATION', 'OFFICE_ID', 'VARCHAR2(30)');
    add_column('USERDETAIL', 'OFFICE_ID', 'VARCHAR2(30)');
    COMMIT;
END;
/

DECLARE
    PROCEDURE create_unique_index(
        p_name  IN VARCHAR2,
        p_table IN VARCHAR2,
        p_expr  IN VARCHAR2
    ) IS
    BEGIN
        EXECUTE IMMEDIATE 'CREATE UNIQUE INDEX ' || p_name ||
                          ' ON ' || p_table || ' (' || p_expr || ')';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE != -955 THEN
                RAISE;
            END IF;
    END;
BEGIN
    create_unique_index('UQ_USERDETAIL_EMAIL',  'USERDETAIL',       'LOWER(TRIM(EMAIL))');
    create_unique_index('UQ_USERDETAIL_MOBILE', 'USERDETAIL',       'TRIM(MOBILE_NO)');
    create_unique_index('UQ_USER_REG_EMAIL',     'USER_REGISTRATION', 'LOWER(TRIM(EMAIL))');
    create_unique_index('UQ_USER_REG_MOBILE',    'USER_REGISTRATION', 'TRIM(MOBILE_NO)');
    COMMIT;
END;
/

CREATE OR REPLACE PROCEDURE SP_SUBMIT_REGISTRATION (
    p_fullname   IN VARCHAR2,
    p_mobile     IN VARCHAR2,
    p_email      IN VARCHAR2,
    p_nid        IN VARCHAR2,
    p_office_id  IN VARCHAR2,
    p_attachment IN VARCHAR2,
    p_success    OUT NUMBER,
    p_msg        OUT VARCHAR2
) AS
    v_email      VARCHAR2(100);
    v_mobile     VARCHAR2(20);
    v_nid        VARCHAR2(30);
    v_office_id  VARCHAR2(30);
    v_user_mobile NUMBER;
    v_user_email  NUMBER;
    v_reg_mobile  NUMBER;
    v_reg_email   NUMBER;
BEGIN
    v_email     := LOWER(TRIM(p_email));
    v_mobile    := TRIM(p_mobile);
    v_nid       := TRIM(p_nid);
    v_office_id := TRIM(p_office_id);

    IF v_email IS NULL OR v_mobile IS NULL THEN
        p_success := 0;
        p_msg     := 'Mobile number and email address are required.';
        RETURN;
    END IF;

    IF v_nid IS NULL
       OR NOT REGEXP_LIKE(v_nid, '^[0-9]{10}$|^[0-9]{13}$|^[0-9]{17}$') THEN
        p_success := 0;
        p_msg     := 'NID number must be exactly 10, 13 or 17 digits.';
        RETURN;
    END IF;

    IF v_office_id IS NULL THEN
        p_success := 0;
        p_msg     := 'Office ID Number is required.';
        RETURN;
    END IF;

    SELECT COUNT(CASE WHEN TRIM(MOBILE_NO) = v_mobile THEN 1 END),
           COUNT(CASE WHEN LOWER(TRIM(EMAIL)) = v_email THEN 1 END)
      INTO v_user_mobile, v_user_email
      FROM USERDETAIL;

    IF v_user_mobile > 0 THEN
        p_success := 0;
        p_msg     := 'This mobile number is already in use by a registered user.';
        RETURN;
    END IF;

    IF v_user_email > 0 THEN
        p_success := 0;
        p_msg     := 'This email address is already in use by a registered user.';
        RETURN;
    END IF;

    SELECT COUNT(CASE WHEN TRIM(MOBILE_NO) = v_mobile THEN 1 END),
           COUNT(CASE WHEN LOWER(TRIM(EMAIL)) = v_email THEN 1 END)
      INTO v_reg_mobile, v_reg_email
      FROM USER_REGISTRATION
     WHERE STATUS = 'PENDING';

    IF v_reg_mobile > 0 THEN
        p_success := 0;
        p_msg     := 'A registration with this mobile number is already awaiting approval. Please contact your manager.';
        RETURN;
    END IF;

    IF v_reg_email > 0 THEN
        p_success := 0;
        p_msg     := 'A registration with this email address is already awaiting approval. Please contact your manager.';
        RETURN;
    END IF;

    INSERT INTO USER_REGISTRATION (FULLNAME, MOBILE_NO, EMAIL, NID, OFFICE_ID, ATTACHMENT_PATH)
    VALUES (p_fullname, v_mobile, v_email, v_nid, v_office_id, p_attachment);

    p_success := 1;
    p_msg     := 'Registration submitted successfully. Awaiting approval.';
EXCEPTION
    WHEN OTHERS THEN
        p_success := 0;
        IF SQLCODE = -1 THEN
            p_msg := 'This mobile number or email address is already in use.';
        ELSE
            p_msg := SQLERRM;
        END IF;
END;
/

CREATE OR REPLACE PROCEDURE SP_GET_PENDING_REGISTRATIONS (
    p_cursor OUT SYS_REFCURSOR
) AS
BEGIN
    OPEN p_cursor FOR
        SELECT REGISTRATION_ID, FULLNAME, MOBILE_NO, EMAIL, NID, ATTACHMENT_PATH, OFFICE_ID
        FROM USER_REGISTRATION
        WHERE STATUS = 'PENDING'
        ORDER BY REGISTRATION_ID DESC;
END;
/

CREATE OR REPLACE PROCEDURE SP_APPROVE_REGISTRATION (
    p_reg_id IN NUMBER,
    p_temp_password IN VARCHAR2,
    p_manager_user_id IN NUMBER,
    o_userid OUT VARCHAR2,
    o_user_email OUT VARCHAR2,
    p_success OUT NUMBER,
    p_msg OUT VARCHAR2
) AS
    v_fullname VARCHAR2(100);
    v_mobile   VARCHAR2(20);
    v_email    VARCHAR2(100);
    v_nid      VARCHAR2(30);
    v_office_id VARCHAR2(30);
    v_attach   VARCHAR2(255);
    v_user_role_id NUMBER;
    v_manager_role VARCHAR2(50);
    v_new_user_id  NUMBER;
    v_count    NUMBER;
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

    SELECT FULLNAME, MOBILE_NO, EMAIL, NID, OFFICE_ID, ATTACHMENT_PATH
    INTO v_fullname, v_mobile, v_email, v_nid, v_office_id, v_attach
    FROM USER_REGISTRATION
    WHERE REGISTRATION_ID = p_reg_id AND STATUS = 'PENDING';

    v_email  := LOWER(TRIM(v_email));
    v_mobile := TRIM(v_mobile);

    IF v_email IS NULL OR v_mobile IS NULL THEN
        p_success := 0;
        p_msg     := 'This registration has no email address or mobile number.';
        RETURN;
    END IF;

    SELECT COUNT(1) INTO v_count
      FROM USERDETAIL
     WHERE LOWER(TRIM(EMAIL)) = v_email
        OR TRIM(MOBILE_NO) = v_mobile;
    IF v_count > 0 THEN
        p_success := 0;
        p_msg     := 'A user with this email address or mobile number already exists. The registration cannot be approved.';
        RETURN;
    END IF;

    o_userid    := 'JB' || FN_GET_NEXT_ID('BANK_USER_SEQ');
    o_user_email := v_email;

    INSERT INTO USERDETAIL (
        USERID, FULLNAME, MOBILE_NO, EMAIL, NID, OFFICE_ID, ATTACHMENT_PATH,
        USERPASSWORD, ROLE_ID, IS_FIRST_LOGIN, USERSTATUS, FAILED_ATTEMPTS,
        APPROVED_BY_USER_ID, APPROVED_AT
    ) VALUES (
        o_userid, v_fullname, v_mobile, v_email, v_nid, v_office_id, v_attach,
        p_temp_password, v_user_role_id, 1, 'Enabled', 0,
        p_manager_user_id, CURRENT_TIMESTAMP
    ) RETURNING USERDETAILID INTO v_new_user_id;

    FOR mc IN (
        SELECT MENU_ID FROM SYSTEM_MENU
        WHERE URL_NAME IN ('dashboard', 'change_password')
    ) LOOP
        INSERT INTO USER_MENU_ASSIGNMENT (USERDETAILID, MENU_ID, ASSIGNED_BY_USER_ID, ASSIGNED_AT)
        VALUES (v_new_user_id, mc.MENU_ID, p_manager_user_id, CURRENT_TIMESTAMP);
    END LOOP;

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
        IF SQLCODE = -1 THEN
            p_msg := 'A user with this email address or mobile number already exists.';
        ELSE
            p_msg := SQLERRM;
        END IF;
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
    v_email             VARCHAR2(100);
    v_mobile            VARCHAR2(20);
    v_count             NUMBER;
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

    v_email  := LOWER(TRIM(p_email));
    v_mobile := TRIM(p_mobile);

    IF v_email IS NULL OR v_mobile IS NULL THEN
        p_success := 0;
        p_msg     := 'Mobile number and email address are required.';
        RETURN;
    END IF;

    SELECT COUNT(1) INTO v_count
      FROM USERDETAIL
     WHERE LOWER(TRIM(EMAIL)) = v_email
        OR TRIM(MOBILE_NO) = v_mobile;
    IF v_count > 0 THEN
        p_success := 0;
        p_msg     := 'A user with this email address or mobile number already exists.';
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
        o_userid, p_fullname, v_mobile, v_email, p_nid, p_image_path, p_temp_password,
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
        IF SQLCODE = -1 THEN
            p_msg := 'A user with this email address or mobile number already exists.';
        ELSE
            p_msg := SQLERRM;
        END IF;
END;
/

DECLARE
    PROCEDURE drop_if_exists(p_table IN VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE 'DROP TABLE ' || p_table || ' CASCADE CONSTRAINTS PURGE';
    EXCEPTION
        WHEN OTHERS THEN
            IF SQLCODE != -942 THEN
                RAISE;
            END IF;
    END;
BEGIN
    drop_if_exists('AUTH_USER_USER_PERMISSIONS');
    drop_if_exists('AUTH_USER_GROUPS');
    drop_if_exists('AUTH_USER');
    drop_if_exists('AUTH_GROUP_PERMISSIONS');
    drop_if_exists('AUTH_GROUP');
    drop_if_exists('AUTH_PERMISSION');
    drop_if_exists('DJANGO_ADMIN_LOG');
    drop_if_exists('DJANGO_CONTENT_TYPE');
    drop_if_exists('DJANGO_MIGRATIONS');
    drop_if_exists('DJANGO_SESSION');
    COMMIT;
END;
/
