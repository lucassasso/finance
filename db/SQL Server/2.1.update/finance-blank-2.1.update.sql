﻿-->-->-- src/Frapid.Web/Areas/MixERP.Finance/db/SQL Server/2.1.update/src/02.functions-and-logic/finance.get_account_statement.sql --<--<--
IF OBJECT_ID('finance.get_account_statement') IS NOT NULL
DROP FUNCTION finance.get_account_statement;

GO

CREATE FUNCTION finance.get_account_statement
(
    @date_from        		date,
    @date_to          		date,
    @user_id                integer,
    @account_id             integer,
    @office_id              integer
)
RETURNS @result TABLE
(
    id                      integer IDENTITY,
	transaction_id			bigint,
	transaction_detail_id	bigint,
    value_date              date,
    book_date               date,
    tran_code               national character varying(50),
    reference_number        national character varying(24),
    statement_reference     national character varying(2000),
    reconciliation_memo     national character varying(2000),
    debit                   numeric(30, 6),
    credit                  numeric(30, 6),
    balance                 numeric(30, 6),
    office 					national character varying(1000),
    book                    national character varying(50),
    account_id              integer,
    account_number 			national character varying(24),
    account                 national character varying(1000),
    posted_on               DATETIMEOFFSET,
    posted_by               national character varying(1000),
    approved_by             national character varying(1000),
    verification_status     integer
)
AS
BEGIN
    DECLARE @normally_debit bit = finance.is_normally_debit(@account_id);

    INSERT INTO @result(value_date, book_date, tran_code, reference_number, statement_reference, debit, credit, office, book, account_id, posted_on, posted_by, approved_by, verification_status)
    SELECT
        @date_from,
        @date_from,
        NULL,
        NULL,
        'Opening Balance',
        NULL,
        SUM
        (
            CASE finance.transaction_details.tran_type
            WHEN 'Cr' THEN amount_in_local_currency
            ELSE amount_in_local_currency * -1 
            END            
        ) as credit,
        NULL,
        NULL,
        NULL,
        NULL,
        NULL,
        NULL,
        NULL
    FROM finance.transaction_master
    INNER JOIN finance.transaction_details
    ON finance.transaction_master.transaction_master_id = finance.transaction_details.transaction_master_id
    WHERE finance.transaction_master.verification_status_id > 0
    AND finance.transaction_master.book_date < @date_from
    AND finance.transaction_master.office_id IN (SELECT * FROM core.get_office_ids(@office_id)) 
    AND finance.transaction_details.account_id IN (SELECT * FROM finance.get_account_ids(@account_id))
    AND finance.transaction_master.deleted = 0;

    DELETE FROM @result
    WHERE COALESCE(debit, 0) = 0
    AND COALESCE(credit, 0) = 0;
    

    UPDATE @result SET 
    debit = credit * -1,
    credit = 0
    WHERE credit < 0;
    

    INSERT INTO @result(transaction_id, transaction_detail_id, value_date, book_date, tran_code, reference_number, statement_reference, reconciliation_memo, debit, credit, office, book, account_id, posted_on, posted_by, approved_by, verification_status)
    SELECT
		finance.transaction_details.transaction_master_id,
		finance.transaction_details.transaction_detail_id,
        finance.transaction_master.value_date,
        finance.transaction_master.book_date,
        finance.transaction_master. transaction_code,
        finance.transaction_master.reference_number,
        finance.transaction_details.statement_reference,
		finance.transaction_details.reconciliation_memo,
        CASE finance.transaction_details.tran_type
        WHEN 'Dr' THEN amount_in_local_currency
        ELSE NULL END,
        CASE finance.transaction_details.tran_type
        WHEN 'Cr' THEN amount_in_local_currency
        ELSE NULL END,
        core.get_office_name_by_office_id(finance.transaction_master.office_id),
        finance.transaction_master.book,
        finance.transaction_details.account_id,
        finance.transaction_master.transaction_ts,
        account.get_name_by_user_id(finance.transaction_master.user_id),
        account.get_name_by_user_id(finance.transaction_master.verified_by_user_id),
        finance.transaction_master.verification_status_id
    FROM finance.transaction_master
    INNER JOIN finance.transaction_details
    ON finance.transaction_master.transaction_master_id = finance.transaction_details.transaction_master_id
    WHERE finance.transaction_master.verification_status_id > 0
    AND finance.transaction_master.book_date >= @date_from
    AND finance.transaction_master.book_date <= @date_to
    AND finance.transaction_master.office_id IN (SELECT * FROM core.get_office_ids(@office_id)) 
    AND finance.transaction_details.account_id IN (SELECT * FROM finance.get_account_ids(@account_id))
    AND finance.transaction_master.deleted = 0
    ORDER BY 
        finance.transaction_master.value_date,
        finance.transaction_master.transaction_ts,
        finance.transaction_master.book_date,
        finance.transaction_master.last_verified_on;



    UPDATE result
    SET balance = c.balance
    FROM @result AS result
    INNER JOIN
    (
        SELECT
            temp_account_statement.id, 
            SUM(COALESCE(c.credit, 0)) 
            - 
            SUM(COALESCE(c.debit,0)) As balance
        FROM @result AS temp_account_statement
        LEFT JOIN @result AS c 
            ON (c.id <= temp_account_statement.id)
        GROUP BY temp_account_statement.id
    ) AS c
    ON result.id = c.id;


    UPDATE result SET 
        account_number = finance.accounts.account_number,
        account = finance.accounts.account_name
    FROM @result AS result
    INNER JOIN finance.accounts
    ON result.account_id = finance.accounts.account_id;



    IF(@normally_debit = 1)
    BEGIN
        UPDATE @result SET balance = balance * -1;
    END;

    RETURN;
END;





GO

--SELECT * FROM finance.get_account_statement('1-1-2010','1-1-2020',1,1,1);


-->-->-- src/Frapid.Web/Areas/MixERP.Finance/db/SQL Server/2.1.update/src/02.functions-and-logic/finance.get_journal_view.sql --<--<--
IF OBJECT_ID('finance.get_journal_view') IS NOT NULL
DROP FUNCTION finance.get_journal_view;

GO

CREATE FUNCTION finance.get_journal_view
(
    @user_id                        integer,
    @office_id                      integer,
    @from                           date,
    @to                             date,
    @tran_id                        bigint,
    @tran_code                      national character varying(50),
    @book                           national character varying(50),
    @reference_number               national character varying(50),
    @amount				            numeric(30, 6),
    @statement_reference            national character varying(2000),
    @posted_by                      national character varying(50),
    @office                         national character varying(50),
    @status                         national character varying(12),
    @verified_by                    national character varying(50),
    @reason                         national character varying(128)
)
RETURNS @result TABLE
(
    transaction_master_id           bigint,
    transaction_code                national character varying(50),
    book                            national character varying(50),
    value_date                      date,
    book_date                          date,
    reference_number                national character varying(24),
    amount				            numeric(30, 6),
	statement_reference             national character varying(2000),
    posted_by                       national character varying(1000),
    office national character varying(1000),
    status                          national character varying(1000),
    verified_by                     national character varying(1000),
    verified_on                     DATETIMEOFFSET,
    reason                          national character varying(128),
    transaction_ts                  DATETIMEOFFSET
)
AS

BEGIN
    WITH office_cte(office_id) AS 
    (
        SELECT @office_id
        UNION ALL
        SELECT
            c.office_id
        FROM 
        office_cte AS p, 
        core.offices AS c 
        WHERE 
        parent_office_id = p.office_id
    )

    INSERT INTO @result
    SELECT 
        finance.transaction_master.transaction_master_id, 
        finance.transaction_master.transaction_code,
        finance.transaction_master.book,
        finance.transaction_master.value_date,
        finance.transaction_master.book_date,
        finance.transaction_master.reference_number,
		SUM
		(
			CASE WHEN finance.transaction_details.tran_type = 'Cr' THEN 1 ELSE 0 END 
				* 
			finance.transaction_details.amount_in_local_currency
		), 
        finance.transaction_master.statement_reference,
        account.get_name_by_user_id(finance.transaction_master.user_id) as posted_by,
        core.get_office_name_by_office_id(finance.transaction_master.office_id) as office,
        finance.get_verification_status_name_by_verification_status_id(finance.transaction_master.verification_status_id) as status,
        account.get_name_by_user_id(finance.transaction_master.verified_by_user_id) as verified_by,
        finance.transaction_master.last_verified_on AS verified_on,
        finance.transaction_master.verification_reason AS reason,    
        finance.transaction_master.transaction_ts
    FROM finance.transaction_master
	INNER JOIN finance.transaction_details
	ON finance.transaction_details.transaction_master_id = finance.transaction_master.transaction_master_id
    WHERE 1 = 1
    AND finance.transaction_master.value_date BETWEEN @from AND @to
    AND finance.transaction_master.office_id IN (SELECT office_id FROM office_cte)
    AND (@tran_id = 0 OR @tran_id  = finance.transaction_master.transaction_master_id)
    AND LOWER(finance.transaction_master.transaction_code) LIKE '%' + LOWER(@tran_code) + '%' 
    AND LOWER(finance.transaction_master.book) LIKE '%' + LOWER(@book) + '%' 
    AND COALESCE(LOWER(finance.transaction_master.reference_number), '') LIKE '%' + LOWER(@reference_number) + '%' 
    AND COALESCE(LOWER(finance.transaction_master.statement_reference), '') LIKE '%' + LOWER(@statement_reference) + '%' 
    AND COALESCE(LOWER(finance.transaction_master.verification_reason), '') LIKE '%' + LOWER(@reason) + '%' 
    AND LOWER(account.get_name_by_user_id(finance.transaction_master.user_id)) LIKE '%' + LOWER(@posted_by) + '%' 
    AND LOWER(core.get_office_name_by_office_id(finance.transaction_master.office_id)) LIKE '%' + LOWER(@office) + '%' 
    AND COALESCE(LOWER(finance.get_verification_status_name_by_verification_status_id(finance.transaction_master.verification_status_id)), '') LIKE '%' + LOWER(@status) + '%' 
    AND COALESCE(LOWER(account.get_name_by_user_id(finance.transaction_master.verified_by_user_id)), '') LIKE '%' + LOWER(@verified_by) + '%'    
    AND finance.transaction_master.deleted = 0
	GROUP BY 
		finance.transaction_master.transaction_master_id, 
        finance.transaction_master.transaction_code,
        finance.transaction_master.book,
        finance.transaction_master.value_date,
        finance.transaction_master.book_date,
        finance.transaction_master.reference_number,
		finance.transaction_master.statement_reference,
		finance.transaction_master.last_verified_on,
        finance.transaction_master.verification_reason,    
        finance.transaction_master.transaction_ts,
		finance.transaction_master.verified_by_user_id,
		finance.transaction_master.user_id,
		finance.transaction_master.office_id,
		finance.transaction_master.verification_status_id
	HAVING SUM
		(
			CASE WHEN finance.transaction_details.tran_type = 'Cr' THEN 1 ELSE 0 END 
				* 
			finance.transaction_details.amount_in_local_currency
		) = @amount
		OR @amount = 0
    ORDER BY value_date ASC, verification_status_id DESC;

    RETURN;
END;

GO



--SELECT * FROM finance.get_journal_view(2,1,'1-1-2000','1-1-2020',0,'', 'Inventory Transfer', '', 0, '','', '','','', '');



-->-->-- src/Frapid.Web/Areas/MixERP.Finance/db/SQL Server/2.1.update/src/02.functions-and-logic/finance.get_new_transaction_counter.sql --<--<--
IF OBJECT_ID('finance.get_new_transaction_counter') IS NOT NULL
DROP FUNCTION finance.get_new_transaction_counter;

GO

CREATE FUNCTION finance.get_new_transaction_counter(@value_date date)
RETURNS integer
AS
BEGIN
    DECLARE @ret_val integer;

    SELECT @ret_val = COALESCE(MAX(transaction_counter),0)
    FROM finance.transaction_master
    WHERE finance.transaction_master.value_date=@value_date;

    IF @ret_val IS NULL
    BEGIN
        SET @ret_val = 1;
    END
    ELSE
    BEGIN
        SET @ret_val = @ret_val + 1;
    END;

    RETURN @ret_val;
END;

GO


-->-->-- src/Frapid.Web/Areas/MixERP.Finance/db/SQL Server/2.1.update/src/02.functions-and-logic/finance.get_transaction_code.sql --<--<--
IF OBJECT_ID('finance.get_transaction_code') IS NOT NULL
DROP FUNCTION finance.get_transaction_code;

GO
CREATE FUNCTION finance.get_transaction_code(@value_date date, @office_id integer, @user_id integer, @login_id bigint)
RETURNS national character varying(48)
AS
BEGIN
    DECLARE @ret_val national character varying(1000);  

    SET @ret_val =	CAST(finance.get_new_transaction_counter(@value_date) AS varchar(24)) + '-' + 
					CONVERT(varchar(10), @value_date, 120) + '-' + 
					CAST(@office_id AS varchar(100)) + '-' + 
					CAST(@user_id AS varchar(100)) + '-' + 
					CAST(@login_id AS varchar(100))   + '-' +  
					CONVERT(VARCHAR(10), GETUTCDATE(), 108);

    RETURN @ret_val;
END;

GO



-->-->-- src/Frapid.Web/Areas/MixERP.Finance/db/SQL Server/2.1.update/src/04.default-values/01.default-values.sql --<--<--
UPDATE finance.accounts
SET account_master_id = finance.get_account_master_id_by_account_master_code('ACP')
WHERE account_name = 'Interest Payable';


UPDATE finance.accounts
SET account_master_id = finance.get_account_master_id_by_account_master_code('FII')
WHERE account_name = 'Finance Charge Income';

IF NOT EXISTS(SELECT 0 FROM finance.account_masters WHERE account_master_code='LOP')
BEGIN
    INSERT INTO finance.account_masters(account_master_id, account_master_code, account_master_name, normally_debit, parent_account_master_id)
    SELECT 15009, 'LOP', 'Loan Payables', 0, 1;

	UPDATE finance.accounts
	SET account_master_id = 15009
	WHERE account_name IN('Loan Payable', 'Bank Loans Payable');
END;

IF NOT EXISTS(SELECT 0 FROM finance.account_masters WHERE account_master_code='LAD') 
BEGIN
    INSERT INTO finance.account_masters(account_master_id, account_master_code, account_master_name, normally_debit, parent_account_master_id)
    SELECT 10104, 'LAD', 'Loan & Advances', 1, 1;

	UPDATE finance.accounts
	SET account_master_id = 10104
	WHERE account_name = 'Loan & Advances';
END;


-->-->-- src/Frapid.Web/Areas/MixERP.Finance/db/SQL Server/2.1.update/src/05.scrud-views/empty.sql --<--<--


-->-->-- src/Frapid.Web/Areas/MixERP.Finance/db/SQL Server/2.1.update/src/05.selector-views/empty.sql --<--<--


-->-->-- src/Frapid.Web/Areas/MixERP.Finance/db/SQL Server/2.1.update/src/05.views/empty.sql --<--<--


-->-->-- src/Frapid.Web/Areas/MixERP.Finance/db/SQL Server/2.1.update/src/06.report-views/empty.sql --<--<--


-->-->-- src/Frapid.Web/Areas/MixERP.Finance/db/SQL Server/2.1.update/src/99.ownership.sql --<--<--
EXEC sp_addrolemember  @rolename = 'db_owner', @membername  = 'frapid_db_user'


EXEC sp_addrolemember  @rolename = 'db_datareader', @membername  = 'report_user'


GO


DECLARE @proc sysname
DECLARE @cmd varchar(8000)

DECLARE cur CURSOR FOR 
SELECT '[' + schema_name(schema_id) + '].[' + name + ']' FROM sys.objects
WHERE type IN('FN')
AND is_ms_shipped = 0
ORDER BY 1
OPEN cur
FETCH next from cur into @proc
WHILE @@FETCH_STATUS = 0
BEGIN
     SET @cmd = 'GRANT EXEC ON ' + @proc + ' TO report_user';
     EXEC (@cmd)

     FETCH next from cur into @proc
END
CLOSE cur
DEALLOCATE cur

GO

