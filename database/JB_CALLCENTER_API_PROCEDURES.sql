
CREATE OR REPLACE PROCEDURE SP_GET_USER_BY_MOBILE (
    p_mobile   IN VARCHAR2,
    o_cursor   OUT SYS_REFCURSOR
) AS
BEGIN
    OPEN o_cursor FOR
        SELECT u.USERDETAILID,
               u.USERID,
               u.FULLNAME,
               u.MOBILE_NO,
               u.EMAIL,
               u.USERSTATUS,
               u.FAILED_ATTEMPTS,
               u.ROLE_ID,
               NVL(r.ROLE_NAME, 'No Role')
          FROM USERDETAIL u
          LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
         WHERE TRIM(u.MOBILE_NO) = TRIM(p_mobile)
         ORDER BY u.USERDETAILID DESC;
END;
/

CREATE OR REPLACE PROCEDURE SP_GET_USER_BY_USERID_EMAIL (
    p_userid        IN  VARCHAR2,
    p_email         IN  VARCHAR2,
    o_userdetailid  OUT NUMBER,
    o_userid        OUT VARCHAR2,
    o_fullname      OUT VARCHAR2,
    o_email         OUT VARCHAR2,
    o_userstatus    OUT VARCHAR2,
    o_found         OUT NUMBER
) AS
BEGIN
    o_found         := 0;
    o_userdetailid  := NULL;
    o_userid        := NULL;
    o_fullname      := NULL;
    o_email         := NULL;
    o_userstatus    := NULL;

    IF TRIM(NVL(p_userid, ' ')) IS NULL
       OR TRIM(NVL(p_email,  ' ')) IS NULL THEN
        RETURN;
    END IF;

    SELECT USERDETAILID, USERID, FULLNAME, EMAIL, USERSTATUS
      INTO o_userdetailid, o_userid, o_fullname, o_email, o_userstatus
      FROM USERDETAIL
     WHERE TRIM(USERID) = TRIM(p_userid)
       AND TRIM(EMAIL)  = TRIM(p_email);

    o_found := 1;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        o_found := 0;
    WHEN OTHERS THEN
        o_found        := 0;
        o_userdetailid := NULL;
        o_userid       := NULL;
        o_fullname     := NULL;
        o_email        := NULL;
        o_userstatus   := NULL;
END;
/

CREATE OR REPLACE PROCEDURE SP_IS_USER_ENABLED (
    p_user_detail_id IN  NUMBER,
    o_enabled        OUT NUMBER
) AS
    v_status VARCHAR2(20);
BEGIN
    o_enabled := 0;

    SELECT UPPER(TRIM(NVL(USERSTATUS, 'Enabled'))) INTO v_status
      FROM USERDETAIL
     WHERE USERDETAILID = p_user_detail_id;

    IF v_status = 'ENABLED' THEN
        o_enabled := 1;
    END IF;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        o_enabled := 0;
    WHEN OTHERS THEN
        o_enabled := 0;
END;
/

CREATE OR REPLACE PROCEDURE SP_GET_USER_DETAIL_ID (
    p_userid        IN  VARCHAR2,
    o_userdetailid  OUT NUMBER
) AS
BEGIN
    o_userdetailid := NULL;

    IF TRIM(NVL(p_userid, ' ')) IS NULL THEN
        RETURN;
    END IF;

    SELECT USERDETAILID INTO o_userdetailid
      FROM USERDETAIL
     WHERE TRIM(USERID) = TRIM(p_userid);

EXCEPTION
    WHEN NO_DATA_FOUND THEN
        o_userdetailid := NULL;
    WHEN OTHERS THEN
        o_userdetailid := NULL;
END;
/

CREATE OR REPLACE PROCEDURE SP_GET_USER_ROLE (
    p_user_detail_id IN  NUMBER,
    o_role_name      OUT VARCHAR2
) AS
BEGIN
    o_role_name := '';

    SELECT NVL(UPPER(TRIM(r.ROLE_NAME)), '') INTO o_role_name
      FROM USERDETAIL u
      LEFT JOIN SYSTEM_ROLE r ON u.ROLE_ID = r.ROLE_ID
     WHERE u.USERDETAILID = p_user_detail_id;

EXCEPTION
    WHEN NO_DATA_FOUND THEN
        o_role_name := '';
    WHEN OTHERS THEN
        o_role_name := '';
END;
/
