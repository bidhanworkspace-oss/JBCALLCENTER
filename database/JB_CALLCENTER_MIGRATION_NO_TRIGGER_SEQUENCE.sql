-- ===========================================================================
--  JB CALL CENTER - MIGRATION: REMOVE TRIGGERS + SEQUENCES, RENAME BANK ID
-- ---------------------------------------------------------------------------
--  Run as the JBCALLCENTER schema user (the same user Django connects with).
--  Idempotent - safe to re-run.
--
--  WHAT THIS SCRIPT DOES (apply ON TOP of the existing database)
--  ----------------------------------------------------------------------
--  1. Drops the explicit sequences:
--       SEQ_BANK_ID, JB_TICKETS_SEQ, JB_TICKET_RESPONSES_SEQ
--     and the triggers:
--       TRG_JB_TICKETS_BI, TRG_JB_TICKET_RESP_BI
--
--  2. Renames the "Bank ID" columns to "User ID":
--       USERDETAIL.BANKID                -> USERID
--       USER_ACTION_AUDIT_LOG.BANK_ID    -> USERID
--       JB_TICKETS.RAISED_BY_BANK_ID     -> RAISED_BY_USERID
--       JB_TICKET_RESPONSES.RESPONDER_BANK_ID -> RESPONDER_USERID
--     (Oracle automatically keeps constraints/indexes pointing at the new
--      column name. The numeric record id stays USERDETAILID / *_USER_ID.)
--
--  3. Creates a plain counter table + function that replace the sequences:
--       JB_APP_COUNTER (COUNTER_NAME, NEXT_VALUE)
--       FN_GET_NEXT_ID(p_counter_name)  -> next id, row-locked (concurrency
--       safe, no gaps). This is a TABLE + FUNCTION, NOT a
--       CREATE SEQUENCE and NOT a trigger.
--
--  4. Recreates every stored procedure so that:
--       - no procedure references a sequence or a trigger anymore
--       - all bank-named parameters / columns use the new "userid" names
--       - ticket ids / response ids / generated user ids come from
--         FN_GET_NEXT_ID()
--
--  5. Adds two new procedures used by the new "User Unlock" page:
--       SP_GET_USER_BY_MOBILE       (search a customer by mobile number)
--       SP_UNLOCK_USER_BY_MOBILE    (unlock + rotate a temp password)
--
--  NOTE about GENERATED ALWAYS AS IDENTITY columns (SYSTEM_ROLE, SYSTEM_MENU,
--  USERDETAIL.USERDETAILID, USER_REGISTRATION, USER_ACTION_AUDIT_LOG.LOG_ID):
--  these are Oracle's built-in identity feature, maintained internally by the
--  engine. They require NO user-created sequence and NO trigger, so they are
--  kept as-is. This script removes every user-created sequence/trigger.
--
--  AFTER RUNNING verify:
--    SELECT sequence_name FROM user_sequences;          -- expect NONE
--    SELECT trigger_name  FROM user_triggers;           -- expect NONE
--    SELECT object_name FROM user_objects WHERE status = 'INVALID';  -- expect NONE
-- ===========================================================================

WHENEVER SQLERROR CONTINUE
/

-- ===========================================================================
-- 1. DROP SEQUENCES + TRIGGERS (best effort)
-- ===========================================================================
BEGIN
    EXECUTE IMMEDIATE 'DROP SEQUENCE SEQ_BANK_ID';
EXCEPTION WHEN OTHERS THEN NULL;
END;
/
BEGIN
    EXECUTE IMMEDIATE 'DROP SEQUENCE JB_TICKETS_SEQ';
EXCEPTION WHEN OTHERS THEN NULL;
END;
/
BEGIN
    EXECUTE IMMEDIATE 'DROP SEQUENCE JB_TICKET_RESPONSES_SEQ';
EXCEPTION WHEN OTHERS THEN NULL;
END;
/
BEGIN
    EXECUTE IMMEDIATE 'DROP TRIGGER TRG_JB_TICKETS_BI';
EXCEPTION WHEN OTHERS THEN NULL;
END;
/
BEGIN
    EXECUTE IMMEDIATE 'DROP TRIGGER TRG_JB_TICKET_RESP_BI';
EXCEPTION WHEN OTHERS THEN NULL;
END;
/

-- ===========================================================================
-- 2. RENAME "BANK ID" COLUMNS -> "USER ID" (guarded)
-- ===========================================================================
DECLARE
    v_cnt NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_cnt FROM ALL_TAB_COLUMNS
     WHERE OWNER = USER AND TABLE_NAME = 'USERDETAIL' AND COLUMN_NAME = 'BANKID';
    IF v_cnt > 0 THEN
        EXECUTE IMMEDIATE 'ALTER TABLE USERDETAIL RENAME COLUMN BANKID TO USERID';
    END IF;

    SELECT COUNT(*) INTO v_cnt FROM ALL_TAB_COLUMNS
     WHERE OWNER = USER AND TABLE_NAME = 'USER_ACTION_AUDIT_LOG' AND COLUMN_NAME = 'BANK_ID';
    IF v_cnt > 0 THEN
        EXECUTE IMMEDIATE 'ALTER TABLE USER_ACTION_AUDIT_LOG RENAME COLUMN BANK_ID TO USERID';
    END IF;

    SELECT COUNT(*) INTO v_cnt FROM ALL_TAB_COLUMNS
     WHERE OWNER = USER AND TABLE_NAME = 'JB_TICKETS' AND COLUMN_NAME = 'RAISED_BY_BANK_ID';
    IF v_cnt > 0 THEN
        EXECUTE IMMEDIATE 'ALTER TABLE JB_TICKETS RENAME COLUMN RAISED_BY_BANK_ID TO RAISED_BY_USERID';
    END IF;

    SELECT COUNT(*) INTO v_cnt FROM ALL_TAB_COLUMNS
     WHERE OWNER = USER AND TABLE_NAME = 'JB_TICKET_RESPONSES' AND COLUMN_NAME = 'RESPONDER_BANK_ID';
    IF v_cnt > 0 THEN
        EXECUTE IMMEDIATE 'ALTER TABLE JB_TICKET_RESPONSES RENAME COLUMN RESPONDER_BANK_ID TO RESPONDER_USERID';
    END IF;
END;
/

-- ===========================================================================
-- 3. COUNTER TABLE + SEQUENCE-REPLACEMENT FUNCTION
-- ===========================================================================
DECLARE
    v_cnt NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_cnt FROM USER_TABLES WHERE TABLE_NAME = 'JB_APP_COUNTER';
    IF v_cnt = 0 THEN
        EXECUTE IMMEDIATE 'CREATE TABLE JB_APP_COUNTER (
            COUNTER_NAME VARCHAR2(60) CONSTRAINT PK_JB_APP_COUNTER PRIMARY KEY,
            NEXT_VALUE   NUMBER       NOT NULL
        )';
    END IF;
END;
/

CREATE OR REPLACE FUNCTION FN_GET_NEXT_ID(p_counter_name IN VARCHAR2) RETURN NUMBER IS
    v_next NUMBER;
BEGIN
    SELECT NEXT_VALUE INTO v_next
      FROM JB_APP_COUNTER
     WHERE COUNTER_NAME = p_counter_name
       FOR UPDATE;

    UPDATE JB_APP_COUNTER SET NEXT_VALUE = v_next + 1
     WHERE COUNTER_NAME = p_counter_name;

    RETURN v_next;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        BEGIN
            INSERT INTO JB_APP_COUNTER (COUNTER_NAME, NEXT_VALUE)
            VALUES (p_counter_name, 2);
            RETURN 1;
        EXCEPTION
            WHEN DUP_VAL_ON_INDEX THEN
                SELECT NEXT_VALUE INTO v_next
                  FROM JB_APP_COUNTER
                 WHERE COUNTER_NAME = p_counter_name
                   FOR UPDATE;
                UPDATE JB_APP_COUNTER SET NEXT_VALUE = v_next + 1
                 WHERE COUNTER_NAME = p_counter_name;
                RETURN v_next;
        END;
END;
/

-- Seed the counters so new ids never collide with existing data.
DECLARE
    v_next NUMBER;
BEGIN
    SELECT NVL(MAX(TICKET_ID), 0) + 1 INTO v_next FROM JB_TICKETS;
    BEGIN
        INSERT INTO JB_APP_COUNTER (COUNTER_NAME, NEXT_VALUE)
        VALUES ('JB_TICKETS_SEQ', v_next);
    EXCEPTION WHEN DUP_VAL_ON_INDEX THEN NULL;
    END;

    SELECT NVL(MAX(RESPONSE_ID), 0) + 1 INTO v_next FROM JB_TICKET_RESPONSES;
    BEGIN
        INSERT INTO JB_APP_COUNTER (COUNTER_NAME, NEXT_VALUE)
        VALUES ('JB_TICKET_RESPONSES_SEQ', v_next);
    EXCEPTION WHEN DUP_VAL_ON_INDEX THEN NULL;
    END;

    SELECT NVL(MAX(TO_NUMBER(SUBSTR(USERID, 3))), 0) + 1 INTO v_next
      FROM USERDETAIL WHERE USERID LIKE 'JB%';
    BEGIN
        INSERT INTO JB_APP_COUNTER (COUNTER_NAME, NEXT_VALUE)
        VALUES ('BANK_USER_SEQ', v_next);
    EXCEPTION WHEN DUP_VAL_ON_INDEX THEN NULL;
    END;

    SELECT NVL(MAX(TO_NUMBER(SUBSTR(USERID, 4))), 0) + 1 INTO v_next
      FROM USERDETAIL WHERE USERID LIKE 'MGR%';
    BEGIN
        INSERT INTO JB_APP_COUNTER (COUNTER_NAME, NEXT_VALUE)
        VALUES ('MANAGER_USER_SEQ', v_next);
    EXCEPTION WHEN DUP_VAL_ON_INDEX THEN NULL;
    END;
    COMMIT;
END;
/

-- ===========================================================================
-- 4. RECREATE ALL STORED PROCEDURES (no sequences, no triggers, new names)
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 4a. AUTHENTICATION / PROFILE
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_AUTHENTICATE_USER (
    p_userid          IN VARCHAR2,
    o_user_detail_id  OUT NUMBER,
    p_hashed_password OUT VARCHAR2,
    p_is_first_login  OUT NUMBER,
    p_user_status     OUT VARCHAR2,
    p_failed_attempts OUT NUMBER,
    p_success         OUT NUMBER,
    p_msg             OUT VARCHAR2
) AS
BEGIN
    SELECT USERDETAILID, USERPASSWORD, IS_FIRST_LOGIN, USERSTATUS, FAILED_ATTEMPTS
    INTO o_user_detail_id, p_hashed_password, p_is_first_login, p_user_status, p_failed_attempts
    FROM USERDETAIL WHERE USERID = p_userid;

    p_success := 1;
    p_msg     := 'User record found.';
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        p_success := 0;
        p_msg     := 'Invalid User ID or Password.';
    WHEN OTHERS THEN
        p_success := 0;
        p_msg     := SQLERRM;
END;
/

CREATE OR REPLACE PROCEDURE SP_GET_USER_MENUS (
    p_user_detail_id IN  NUMBER,
    p_menu_cursor    OUT SYS_REFCURSOR
) AS
BEGIN
    OPEN p_menu_cursor FOR
        SELECT DISTINCT m.MENU_ID,
                        m.MENU_TITLE,
                        m.URL_NAME,
                        m.PARENT_ID,
                        m.ICON_CLASS,
                        m.DISPLAY_ORDER
          FROM SYSTEM_MENU m
               JOIN ROLE_MENU_PERMISSION rmp ON m.MENU_ID = rmp.MENU_ID
               JOIN USERDETAIL u ON u.ROLE_ID = rmp.ROLE_ID
         WHERE u.USERDETAILID = p_user_detail_id
      ORDER BY m.PARENT_ID NULLS FIRST, m.DISPLAY_ORDER ASC;
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
    JOIN ROLE_MENU_PERMISSION rmp ON m.MENU_ID = rmp.MENU_ID
    JOIN USERDETAIL u ON u.ROLE_ID = rmp.ROLE_ID
    WHERE u.USERDETAILID = p_user_detail_id AND m.URL_NAME = p_url_name;

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

CREATE OR REPLACE PROCEDURE SP_RECORD_AUDIT_LOG (
    p_user_detail_id IN NUMBER,
    p_userid         IN VARCHAR2,
    p_role_name      IN VARCHAR2,
    p_action_type    IN VARCHAR2,
    p_url_path       IN VARCHAR2,
    p_http_method    IN VARCHAR2,
    p_ip_address     IN VARCHAR2,
    p_request_data   IN CLOB,
    p_response_status IN NUMBER
) AS
PRAGMA AUTONOMOUS_TRANSACTION;
BEGIN
    INSERT INTO USER_ACTION_AUDIT_LOG (
        USER_ID, USERID, ROLE_NAME, ACTION_TYPE, URL_PATH,
        HTTP_METHOD, IP_ADDRESS, REQUEST_DATA, RESPONSE_STATUS, "TIMESTAMP"
    ) VALUES (
        p_user_detail_id, p_userid, p_role_name, p_action_type, p_url_path,
        p_http_method, p_ip_address, p_request_data, p_response_status, CURRENT_TIMESTAMP
    );
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        NULL;
END;
/

CREATE OR REPLACE PROCEDURE SP_GET_AUDIT_LOGS (
    p_cursor OUT SYS_REFCURSOR
) AS
BEGIN
    OPEN p_cursor FOR
        SELECT LOG_ID, "TIMESTAMP", USERID, ROLE_NAME, ACTION_TYPE, URL_PATH, IP_ADDRESS, RESPONSE_STATUS
        FROM USER_ACTION_AUDIT_LOG
        ORDER BY LOG_ID DESC
        FETCH FIRST 100 ROWS ONLY;
END;
/

CREATE OR REPLACE PROCEDURE SP_GET_USER_DETAILS (
    p_user_detail_id IN  NUMBER,
    o_fullname       OUT VARCHAR2,
    o_email          OUT VARCHAR2,
    o_image_path     OUT VARCHAR2,
    o_role_name      OUT VARCHAR2,
    o_success        OUT NUMBER
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
     WHERE u.USERDETAILID = p_user_detail_id;

    o_success := 1;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        o_success := 0;
    WHEN OTHERS THEN
        o_success := 0;
END;
/

-- ---------------------------------------------------------------------------
-- 4b. REGISTRATION / APPROVAL
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_SUBMIT_REGISTRATION (
    p_fullname IN VARCHAR2,
    p_mobile IN VARCHAR2,
    p_email IN VARCHAR2,
    p_nid IN VARCHAR2,
    p_attachment IN VARCHAR2,
    p_success OUT NUMBER,
    p_msg OUT VARCHAR2
) AS
BEGIN
    INSERT INTO USER_REGISTRATION (FULLNAME, MOBILE_NO, EMAIL, NID, ATTACHMENT_PATH)
    VALUES (p_fullname, p_mobile, p_email, p_nid, p_attachment);

    p_success := 1;
    p_msg     := 'Registration submitted successfully. Awaiting approval.';
EXCEPTION
    WHEN OTHERS THEN
        p_success := 0;
        p_msg     := SQLERRM;
END;
/

CREATE OR REPLACE PROCEDURE SP_GET_PENDING_REGISTRATIONS (
    p_cursor OUT SYS_REFCURSOR
) AS
BEGIN
    OPEN p_cursor FOR
        SELECT REGISTRATION_ID, FULLNAME, MOBILE_NO, EMAIL, NID, ATTACHMENT_PATH
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
    v_attach   VARCHAR2(255);
    v_user_role_id NUMBER;
    v_manager_role VARCHAR2(50);
    v_new_user_id  NUMBER;
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

    o_userid    := 'JB' || FN_GET_NEXT_ID('BANK_USER_SEQ');
    o_user_email := v_email;

    INSERT INTO USERDETAIL (
        USERID, FULLNAME, MOBILE_NO, EMAIL, NID, ATTACHMENT_PATH,
        USERPASSWORD, ROLE_ID, IS_FIRST_LOGIN, USERSTATUS, FAILED_ATTEMPTS,
        APPROVED_BY_USER_ID, APPROVED_AT
    ) VALUES (
        o_userid, v_fullname, v_mobile, v_email, v_nid, v_attach,
        p_temp_password, v_user_role_id, 1, 'Enabled', 0,
        p_manager_user_id, CURRENT_TIMESTAMP
    ) RETURNING USERDETAILID INTO v_new_user_id;

    -- Default menu grants: a newly approved user starts with ONLY
    -- Dashboard + Change Password. More menus are added via Assign Menu.
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
        p_msg     := SQLERRM;
END;
/

CREATE OR REPLACE PROCEDURE SP_CREATE_MANAGER_BY_SUPERADMIN (
    p_superadmin_user_id IN NUMBER,
    p_fullname IN VARCHAR2,
    p_mobile IN VARCHAR2,
    p_email IN VARCHAR2,
    p_nid IN VARCHAR2,
    p_image_path IN VARCHAR2,
    p_temp_password IN VARCHAR2,
    o_userid OUT VARCHAR2,
    p_success OUT NUMBER,
    p_msg OUT VARCHAR2
) AS
    v_role_id NUMBER;
    v_superadmin_role VARCHAR2(50);
    v_new_user_id  NUMBER;
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

    o_userid := 'MGR' || FN_GET_NEXT_ID('MANAGER_USER_SEQ');

    INSERT INTO USERDETAIL (
        USERID, FULLNAME, MOBILE_NO, EMAIL, NID, IMAGE_PATH, USERPASSWORD,
        ROLE_ID, IS_FIRST_LOGIN, USERSTATUS, APPROVED_BY_USER_ID, APPROVED_AT
    ) VALUES (
        o_userid, p_fullname, p_mobile, p_email, p_nid, p_image_path, p_temp_password,
        v_role_id, 1, 'Enabled', p_superadmin_user_id, CURRENT_TIMESTAMP
    ) RETURNING USERDETAILID INTO v_new_user_id;

    -- Standard manager menu set (fine-tuned later via Assign Menu).
    FOR mc IN (
        SELECT MENU_ID FROM SYSTEM_MENU
        WHERE URL_NAME IN (
            'dashboard', 'manager_dashboard', 'pending_registration',
            'user_unlock', 'assign_menu', 'approve_user', 'unlock_user',
            'audit_trail', 'change_password', 'raise_ticket', 'tickets'
        )
    ) LOOP
        INSERT INTO USER_MENU_ASSIGNMENT (USERDETAILID, MENU_ID, ASSIGNED_BY_USER_ID, ASSIGNED_AT)
        VALUES (v_new_user_id, mc.MENU_ID, p_superadmin_user_id, CURRENT_TIMESTAMP);
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

-- ---------------------------------------------------------------------------
-- 4c. UNLOCK / PASSWORD
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_UNLOCK_USER_BY_MANAGER (
    p_userid IN VARCHAR2,
    p_temp_hashed_password IN VARCHAR2,
    o_email OUT VARCHAR2,
    p_success OUT NUMBER,
    p_msg OUT VARCHAR2
) AS
BEGIN
    SELECT EMAIL INTO o_email FROM USERDETAIL WHERE USERID = p_userid;

    UPDATE USERDETAIL
    SET USERPASSWORD = p_temp_hashed_password,
        USERSTATUS = 'Enabled',
        IS_FIRST_LOGIN = 1,
        FAILED_ATTEMPTS = 0
    WHERE USERID = p_userid;

    p_success := 1;
    p_msg     := 'User unlocked and temporary password set.';
    COMMIT;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        p_success := 0;
        p_msg     := 'User ID not found.';
    WHEN OTHERS THEN
        p_success := 0;
        p_msg     := SQLERRM;
END;
/

CREATE OR REPLACE PROCEDURE SP_CHANGE_PASSWORD (
    p_user_detail_id IN NUMBER,
    p_new_hashed_password IN VARCHAR2,
    p_success OUT NUMBER,
    p_msg OUT VARCHAR2
) AS
BEGIN
    UPDATE USERDETAIL
    SET USERPASSWORD = p_new_hashed_password,
        IS_FIRST_LOGIN = 0,
        USERSTATUS = 'Enabled',
        FAILED_ATTEMPTS = 0
    WHERE USERDETAILID = p_user_detail_id;

    p_success := 1;
    p_msg     := 'Password updated successfully.';
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        p_success := 0;
        p_msg     := SQLERRM;
END;
/

CREATE OR REPLACE PROCEDURE SP_CHANGE_USER_PASSWORD (
    p_user_detail_id IN NUMBER,
    p_old_hashed_password IN VARCHAR2,
    p_new_hashed_password IN VARCHAR2,
    p_success OUT NUMBER,
    p_msg OUT VARCHAR2
) AS
    v_db_password VARCHAR2(255);
BEGIN
    SELECT USERPASSWORD INTO v_db_password FROM USERDETAIL WHERE USERDETAILID = p_user_detail_id;

    IF v_db_password IS NULL THEN
        p_success := 0;
        p_msg     := 'User not found.';
        RETURN;
    END IF;

    UPDATE USERDETAIL
    SET USERPASSWORD = p_new_hashed_password, IS_FIRST_LOGIN = 0
    WHERE USERDETAILID = p_user_detail_id;

    p_success := 1;
    p_msg     := 'Password updated successfully.';
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        p_success := 0;
        p_msg     := SQLERRM;
END;
/

CREATE OR REPLACE PROCEDURE SP_FORGOT_PASSWORD_RESET (
    p_userid IN VARCHAR2,
    p_email IN VARCHAR2,
    p_temp_hashed_password IN VARCHAR2,
    o_user_detail_id OUT NUMBER,
    p_success OUT NUMBER,
    p_msg OUT VARCHAR2
) AS
BEGIN
    SELECT USERDETAILID INTO o_user_detail_id
    FROM USERDETAIL
    WHERE USERID = p_userid AND EMAIL = p_email;

    UPDATE USERDETAIL
    SET USERPASSWORD = p_temp_hashed_password,
        IS_FIRST_LOGIN = 1,
        USERSTATUS = 'Enabled',
        FAILED_ATTEMPTS = 0
    WHERE USERDETAILID = o_user_detail_id;

    p_success := 1;
    p_msg     := 'Password reset. Temporary password sent to email.';
    COMMIT;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        p_success := 0;
        p_msg     := 'No matching active user found with provided User ID and Email.';
    WHEN OTHERS THEN
        p_success := 0;
        p_msg     := SQLERRM;
END;
/

-- ---------------------------------------------------------------------------
-- 4d. DASHBOARD LISTS
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_GET_ACTIVE_USERS (
    p_out_cursor OUT SYS_REFCURSOR
) AS
BEGIN
    OPEN p_out_cursor FOR
        SELECT u.USERID,
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

CREATE OR REPLACE PROCEDURE SP_GET_LOCKED_USERS (
    p_out_cursor OUT SYS_REFCURSOR
) AS
BEGIN
    OPEN p_out_cursor FOR
        SELECT u.USERID,
               u.FULLNAME,
               u.EMAIL,
               u.USERSTATUS,
               u.FAILED_ATTEMPTS
        FROM   USERDETAIL u
        WHERE  UPPER(u.USERSTATUS) <> 'ENABLED'
        ORDER  BY u.USERDETAILID DESC;
END;
/

-- ---------------------------------------------------------------------------
-- 4e. TICKETS
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_RAISE_TICKET (
    p_raised_by_user_detail_id IN NUMBER,
    p_raised_by_userid IN VARCHAR2,
    p_issue_type_id     IN NUMBER,
    p_issue_type_name   IN VARCHAR2,
    p_customer_name     IN VARCHAR2,
    p_mobile_no         IN VARCHAR2,
    p_account_no        IN VARCHAR2,
    p_remarks           IN VARCHAR2,
    p_attachment_path   IN VARCHAR2,
    p_priority          IN VARCHAR2,
    o_ticket_id         OUT NUMBER,
    o_ticket_ref        OUT VARCHAR2,
    o_success           OUT NUMBER,
    o_msg               OUT VARCHAR2
) AS
    v_ticket_id NUMBER;
    v_ticket_ref VARCHAR2(30);
BEGIN
    o_success := 0;

    IF p_priority NOT IN ('VERY HIGH','HIGH','LOW') THEN
        o_msg := 'Invalid priority.';
        RETURN;
    END IF;

    IF p_issue_type_id IS NULL THEN
        o_msg := 'Select an issue type.';
        RETURN;
    END IF;

    IF p_mobile_no IS NULL AND p_account_no IS NULL THEN
        o_msg := 'Provide at least Mobile No or Account No.';
        RETURN;
    END IF;

    v_ticket_id  := FN_GET_NEXT_ID('JB_TICKETS_SEQ');
    v_ticket_ref := 'TKT-' || TO_CHAR(SYSDATE, 'YYYYMMDD') || '-' || LPAD(v_ticket_id, 4, '0');

    INSERT INTO JB_TICKETS (
        TICKET_ID, TICKET_REF_NO,
        ISSUE_TYPE_ID, ISSUE_TYPE_NAME,
        RAISED_BY_USER_ID, RAISED_BY_USERID,
        CUSTOMER_NAME, MOBILE_NO, ACCOUNT_NO, REMARKS, ATTACHMENT_PATH,
        PRIORITY
    ) VALUES (
        v_ticket_id, v_ticket_ref,
        p_issue_type_id, p_issue_type_name,
        p_raised_by_user_detail_id, p_raised_by_userid,
        p_customer_name, p_mobile_no, p_account_no, p_remarks, p_attachment_path,
        p_priority
    );

    o_ticket_id  := v_ticket_id;
    o_ticket_ref := v_ticket_ref;
    o_success    := 1;
    o_msg        := 'Ticket raised.';
    COMMIT;
EXCEPTION
    WHEN OTHERS THEN
        o_success := 0;
        o_msg     := SQLERRM;
END;
/

CREATE OR REPLACE PROCEDURE SP_GET_TICKETS (
    p_filter     IN VARCHAR2 DEFAULT 'LATEST',
    p_out_cursor OUT SYS_REFCURSOR
) AS
BEGIN
    IF UPPER(NVL(p_filter, 'LATEST')) = 'PRIORITY' THEN
        OPEN p_out_cursor FOR
            SELECT t.TICKET_ID,
                   t.TICKET_REF_NO,
                   t.ISSUE_TYPE_NAME,
                   t.CUSTOMER_NAME,
                   t.MOBILE_NO,
                   t.ACCOUNT_NO,
                   t.PRIORITY,
                   t.STATUS,
                   t.RAISED_BY_USERID,
                   t.CREATED_AT,
                   (SELECT COUNT(*) FROM JB_TICKET_RESPONSES r
                     WHERE r.TICKET_ID = t.TICKET_ID) AS RESPONSE_COUNT,
                   CASE WHEN t.STATUS IN ('SOLVED','DENIED') THEN NULL
                        ELSE ROUND(SYSDATE - CAST(t.CREATED_AT AS DATE)) END AS OPEN_DAYS
            FROM   JB_TICKETS t
            ORDER  BY CASE t.PRIORITY
                         WHEN 'VERY HIGH' THEN 1
                         WHEN 'HIGH'      THEN 2
                         ELSE 3
                      END,
                      t.CREATED_AT DESC;
    ELSE
        OPEN p_out_cursor FOR
            SELECT t.TICKET_ID,
                   t.TICKET_REF_NO,
                   t.ISSUE_TYPE_NAME,
                   t.CUSTOMER_NAME,
                   t.MOBILE_NO,
                   t.ACCOUNT_NO,
                   t.PRIORITY,
                   t.STATUS,
                   t.RAISED_BY_USERID,
                   t.CREATED_AT,
                   (SELECT COUNT(*) FROM JB_TICKET_RESPONSES r
                     WHERE r.TICKET_ID = t.TICKET_ID) AS RESPONSE_COUNT,
                   CASE WHEN t.STATUS IN ('SOLVED','DENIED') THEN NULL
                        ELSE ROUND(SYSDATE - CAST(t.CREATED_AT AS DATE)) END AS OPEN_DAYS
            FROM   JB_TICKETS t
            ORDER  BY t.CREATED_AT DESC;
    END IF;
END;
/

-- NOTE: single-cursor + EXECUTE IMMEDIATE is required. python-oracledb (thin)
-- hangs on MULTIPLE OUT SYS_REFCURSOR vars, and on a NUMBER as the first bind
-- of a ref-cursor call. The Django app passes TICKET_ID as a string.
CREATE OR REPLACE PROCEDURE SP_GET_TICKET_BY_ID (
    p_ticket_id     IN NUMBER,
    o_ticket_cursor OUT SYS_REFCURSOR
) AS
BEGIN
    OPEN o_ticket_cursor FOR
        'SELECT TICKET_ID, TICKET_REF_NO, ISSUE_TYPE_NAME,
                CUSTOMER_NAME, MOBILE_NO, ACCOUNT_NO,
                REMARKS, ATTACHMENT_PATH, PRIORITY, STATUS,
                RAISED_BY_USERID, CREATED_AT
         FROM   JB_TICKETS
         WHERE  TICKET_ID = :b'
        USING p_ticket_id;
END;
/

CREATE OR REPLACE PROCEDURE SP_GET_TICKET_RESPONSES (
    p_ticket_id     IN NUMBER,
    o_response_cur  OUT SYS_REFCURSOR
) AS
BEGIN
    OPEN o_response_cur FOR
        'SELECT RESPONDER_USERID,
                ACTION_TAKEN,
                REMARKS,
                CREATED_AT
         FROM   JB_TICKET_RESPONSES
         WHERE  TICKET_ID = :b
         ORDER  BY CREATED_AT ASC'
        USING p_ticket_id;
END;
/

CREATE OR REPLACE PROCEDURE SP_RESPOND_TICKET (
    p_ticket_id         IN NUMBER,
    p_responder_user_detail_id IN NUMBER,
    p_responder_userid  IN VARCHAR2,
    p_action            IN VARCHAR2,
    p_remarks           IN VARCHAR2,
    o_success           OUT NUMBER,
    o_msg               OUT VARCHAR2
) AS
    v_status VARCHAR2(20);
    v_responder_role VARCHAR2(50);
BEGIN
    o_success := 0;

    -- Bank Support gate
    SELECT UPPER(NVL(r.ROLE_NAME, ''))
      INTO v_responder_role
      FROM USERDETAIL u
      LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
     WHERE u.USERDETAILID = p_responder_user_detail_id;

    IF v_responder_role <> 'BANK SUPPORT' THEN
        o_msg := 'Access Denied: Only Bank Support users can take action on tickets.';
        RETURN;
    END IF;

    IF p_action NOT IN ('SOLVED','DENIED','NOTE') THEN
        o_msg := 'Invalid action.';
        RETURN;
    END IF;

    IF TRIM(NVL(p_remarks, ' ')) IS NULL THEN
        o_msg := 'Remarks are required before responding.';
        RETURN;
    END IF;

    BEGIN
        SELECT STATUS INTO v_status
        FROM   JB_TICKETS
        WHERE  TICKET_ID = p_ticket_id
        FOR UPDATE;

        IF NVL(v_status, 'CLOSED') IN ('SOLVED','DENIED') AND p_action IN ('SOLVED','DENIED') THEN
            o_msg := 'This ticket is already closed.';
            RETURN;
        END IF;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            o_msg := 'Ticket not found.';
            RETURN;
    END;

    INSERT INTO JB_TICKET_RESPONSES (
        RESPONSE_ID, TICKET_ID,
        RESPONDER_USER_ID, RESPONDER_USERID,
        ACTION_TAKEN, REMARKS
    ) VALUES (
        FN_GET_NEXT_ID('JB_TICKET_RESPONSES_SEQ'), p_ticket_id,
        p_responder_user_detail_id, p_responder_userid,
        p_action, TRIM(p_remarks)
    );

    IF p_action = 'SOLVED' THEN
        UPDATE JB_TICKETS SET STATUS = 'SOLVED', SOLVED_AT = SYSTIMESTAMP
        WHERE TICKET_ID = p_ticket_id;
    ELSIF p_action = 'DENIED' THEN
        UPDATE JB_TICKETS SET STATUS = 'DENIED', SOLVED_AT = SYSTIMESTAMP
        WHERE TICKET_ID = p_ticket_id;
    ELSE
        IF v_status = 'OPEN' THEN
            UPDATE JB_TICKETS SET STATUS = 'IN_PROGRESS'
            WHERE TICKET_ID = p_ticket_id;
        END IF;
    END IF;

    o_success := 1;
    o_msg     := 'Response recorded.';
    COMMIT;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        o_msg := 'Responder not found.';
    WHEN OTHERS THEN
        o_success := 0;
        o_msg     := SQLERRM;
END;
/

-- ---------------------------------------------------------------------------
-- 4f. MENU-BASED ACCESS
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_GET_ASSIGNABLE_MENUS (
    p_actor_user_id IN NUMBER,
    o_cursor        OUT SYS_REFCURSOR
) AS
BEGIN
    OPEN o_cursor FOR
        SELECT m.MENU_ID,
               m.MENU_TITLE,
               m.URL_NAME,
               NVL(m.ICON_CLASS, '')
          FROM USER_MENU_ASSIGNMENT uma
          JOIN SYSTEM_MENU m ON uma.MENU_ID = m.MENU_ID
         WHERE uma.USERDETAILID = p_actor_user_id
           AND m.PARENT_ID IS NULL
         ORDER BY m.DISPLAY_ORDER, m.MENU_TITLE;
END;
/

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
            SELECT CAST(NULL AS VARCHAR2(30)),
                   CAST(NULL AS NUMBER),
                   CAST(NULL AS VARCHAR2(100)),
                   CAST(NULL AS VARCHAR2(100)),
                   CAST(NULL AS VARCHAR2(20)),
                   CAST(NULL AS VARCHAR2(50)),
                   CAST(NULL AS NUMBER),
                   CAST(NULL AS VARCHAR2(4000)),
                   CAST(NULL AS VARCHAR2(4000))
              FROM DUAL
             WHERE 1 = 0;
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        OPEN o_cursor FOR
            SELECT CAST(NULL AS VARCHAR2(30)),
                   CAST(NULL AS NUMBER),
                   CAST(NULL AS VARCHAR2(100)),
                   CAST(NULL AS VARCHAR2(100)),
                   CAST(NULL AS VARCHAR2(20)),
                   CAST(NULL AS VARCHAR2(50)),
                   CAST(NULL AS NUMBER),
                   CAST(NULL AS VARCHAR2(4000)),
                   CAST(NULL AS VARCHAR2(4000))
              FROM DUAL
             WHERE 1 = 0;
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
    v_actor_role  VARCHAR2(50);
    v_target_id   NUMBER;
    v_target_role VARCHAR2(50) := '';
    v_menu_count  NUMBER;
    v_cnt         NUMBER;
    v_menu_title  VARCHAR2(100);
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

    SELECT MENU_TITLE INTO v_menu_title
      FROM SYSTEM_MENU
     WHERE MENU_ID = p_menu_id;

    SELECT COUNT(1) INTO v_cnt
      FROM USER_MENU_ASSIGNMENT
     WHERE USERDETAILID = p_actor_user_id AND MENU_ID = p_menu_id;

    IF v_cnt = 0 THEN
        p_msg := 'Access Denied: You may only grant menus that are assigned to you.';
        RETURN;
    END IF;

    SELECT COUNT(1) INTO v_menu_count
      FROM USER_MENU_ASSIGNMENT
     WHERE USERDETAILID = v_target_id AND MENU_ID = p_menu_id;

    IF p_enable = 1 THEN
        IF v_menu_count > 0 THEN
            p_msg := 'Menu already assigned to the user.';
            RETURN;
        END IF;
        INSERT INTO USER_MENU_ASSIGNMENT (USERDETAILID, MENU_ID, ASSIGNED_BY_USER_ID, ASSIGNED_AT)
        VALUES (v_target_id, p_menu_id, p_actor_user_id, CURRENT_TIMESTAMP);
        p_msg := 'Menu "' || v_menu_title || '" assigned to ' || p_target_userid || '.';
    ELSE
        IF v_menu_count = 0 THEN
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

CREATE OR REPLACE PROCEDURE SP_ASSIGN_BANK_SUPPORT_ROLE (
    p_actor_user_id  IN NUMBER,
    p_target_userid  IN VARCHAR2,
    p_enable         IN NUMBER,
    p_success        OUT NUMBER,
    p_msg            OUT VARCHAR2
) AS
    v_actor_role   VARCHAR2(50);
    v_target_id    NUMBER;
    v_target_role  VARCHAR2(50) := '';
    v_support_role_id NUMBER;
    v_user_role_id NUMBER;
BEGIN
    p_success := 0;

    SELECT UPPER(NVL(r.ROLE_NAME, ''))
      INTO v_actor_role
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

    SELECT ROLE_ID INTO v_support_role_id
      FROM SYSTEM_ROLE
     WHERE UPPER(ROLE_NAME) = 'BANK SUPPORT';

    SELECT ROLE_ID INTO v_user_role_id
      FROM SYSTEM_ROLE
     WHERE UPPER(ROLE_NAME) = 'USER';

    IF p_enable = 1 THEN
        IF v_target_role NOT IN ('USER', 'BANK SUPPORT') THEN
            p_msg := 'Only regular users can be made Bank Support.';
            RETURN;
        END IF;
        UPDATE USERDETAIL SET ROLE_ID = v_support_role_id WHERE USERDETAILID = v_target_id;
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
    WHEN OTHERS THEN
        p_success := 0;
        p_msg     := SQLERRM;
END;
/

-- ===========================================================================
-- 5. NEW PROCEDURES FOR THE "USER UNLOCK" SEARCH PAGE
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- SP_GET_USER_BY_MOBILE
--   Returns the customer's details + status searched by mobile number.
--   Columns: userid, fullname, mobile_no, email, userstatus, failed_attempts, role_name
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_GET_USER_BY_MOBILE (
    p_mobile   IN VARCHAR2,
    o_cursor   OUT SYS_REFCURSOR
) AS
BEGIN
    OPEN o_cursor FOR
        SELECT u.USERID,
               u.FULLNAME,
               u.MOBILE_NO,
               u.EMAIL,
               u.USERSTATUS,
               u.FAILED_ATTEMPTS,
               NVL(r.ROLE_NAME, 'No Role')
          FROM USERDETAIL u
          LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
         WHERE TRIM(u.MOBILE_NO) = TRIM(p_mobile)
         ORDER BY u.USERDETAILID DESC;
END;
/

-- ---------------------------------------------------------------------------
-- SP_UNLOCK_USER_BY_MOBILE
--   Unlocks the newest matching user for the mobile number and installs a
--   temporary password (caller emails it).
--   Returns o_userid + o_email for the notification.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SP_UNLOCK_USER_BY_MOBILE (
    p_mobile   IN VARCHAR2,
    p_temp_hashed_password IN VARCHAR2,
    o_userid   OUT VARCHAR2,
    o_email    OUT VARCHAR2,
    p_success  OUT NUMBER,
    p_msg      OUT VARCHAR2
) AS
    v_user_detail_id NUMBER;
BEGIN
    SELECT USERDETAILID INTO v_user_detail_id
      FROM (SELECT USERDETAILID
              FROM USERDETAIL
             WHERE TRIM(MOBILE_NO) = TRIM(p_mobile)
             ORDER BY USERDETAILID DESC)
     WHERE ROWNUM = 1;

    SELECT USERID, EMAIL INTO o_userid, o_email
      FROM USERDETAIL WHERE USERDETAILID = v_user_detail_id;

    UPDATE USERDETAIL
       SET USERPASSWORD = p_temp_hashed_password,
           USERSTATUS   = 'Enabled',
           IS_FIRST_LOGIN = 1,
           FAILED_ATTEMPTS = 0
     WHERE USERDETAILID = v_user_detail_id;

    p_success := 1;
    p_msg     := 'User unlocked and temporary password set.';
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

COMMIT;

-- ===========================================================================
--  DONE. Verify with:
--    SELECT sequence_name FROM user_sequences;   -- expect no rows
--    SELECT trigger_name  FROM user_triggers;    -- expect no rows
--    SELECT object_name FROM user_objects WHERE status = 'INVALID';   -- none
--  Then run  manage.py check on Django and re-login with SA001 / Admin@123.
-- ===========================================================================