local BANK_CODE = "Lloyds Bank UK"

WebBanking{version     = 1.02,
           country     = "de",
           url         = "https://online.lloydsbank.co.uk/personal/logon/login.jsp",
           services    = {BANK_CODE},
           description = string.format(MM.localizeText("Get balance and transactions for %s"), BANK_CODE)}

function SupportsBank (protocol, bankCode)
    return bankCode == BANK_CODE and protocol == "Web Banking"
end


local connection = nil
local logoutUrl = nil
local startPage = nil

-- session -------------------------------------------------------------------------------------------------------------

function InitializeSession (protocol, bankCode, username, username2, password, username3)
    local index, _, pass, memo = string.find(password, "^(.+)%-([%w]+)$")
    if index ~= 1 then
        return "Please enter your password followed by a minus sign and your memorable information. (ex: password-memorable_information)"
    end

    connection = Connection()

    -- step 1 (username/password)
    local step1Page = HTML(connection:get(url))
    step1Page:xpath("//input[@id='frmLogin:strCustomerLogin_userID']"):attr("value", username)
    step1Page:xpath("//input[@id='frmLogin:strCustomerLogin_pwd']"):attr("value", pass)

    local step2Page = HTML(connection:request(step1Page:xpath("//*[@id='frmLogin:btnLogin2']"):click()))

    local errorElement = step2Page:xpath("//*[@class='formSubmitError']")
    if errorElement:length() > 0 then
        return errorElement:text()
    end

    -- step 2 (memorable information)
    for i = 1, 3 do
        local challangeStr = step2Page:xpath("//label[@for='frmentermemorableinformation1:strEnterMemorableInformation_memInfo" .. i .. "']"):text()
        local characterIndex = tonumber(string.match(challangeStr, "^Character (%d+)"))

        if characterIndex > string.len(memo) then
            return "Memorable information is incorrect."
        end

        local answer = string.sub(memo, characterIndex, characterIndex)
        step2Page:xpath("//select[@id='frmentermemorableinformation1:strEnterMemorableInformation_memInfo" .. i .. "']"):select("&nbsp;" .. answer)
    end

    -- step 3 (skip messages or assign startpage)
    local step3Page = HTML(connection:request(step2Page:xpath("//input[@id='frmentermemorableinformation1:btnContinue']"):click()))

    local errorElement = step3Page:xpath("//*[@class='formSubmitError']")
    if errorElement:length() > 0 then
        return errorElement:text()
    end

    local skipMessagesButton = step3Page:xpath("//input[@id='frmmandatoryMsgs:continue_to_your_accounts2']")

    if skipMessagesButton:length() == 1 then
        print("Unread mandatory messages available. Log on to website to read them.")
        startPage = HTML(connection:request(skipMessagesButton:click()))
    else
        startPage = step3Page
    end

    -- startpage
    local logoutButton = startPage:xpath("//a[@id='ifCommercial:ifCustomerBar:ifMobLO:outputLinkLogOut']")

    if logoutButton:length() == 1 then
        logoutUrl = logoutButton:attr("href")

        print(startPage:xpath("//*[@class='m-hf-02-logged-in']"):text())
    else
        return LoginFailed
    end
end


function EndSession()
    print(HTML(connection:request("GET", logoutUrl)):xpath("//h1"):text())
end

-- accounts ------------------------------------------------------------------------------------------------------------

function ListAccounts(knownAccounts)
    local accounts = {}

    startPage:xpath("//div[@data-tracking-model='CurrentAccountTile' or @data-tracking-model='SavingsAccountTile']"):each(
        function(index, element)
            local accountType = AccountTypeGiro
            if element:attr("data-tracking-model") == "SavingsAccountTile" then
                accountType = AccountTypeSavings
            end
            
            local iban, bic, accountNumber, sortCode = getSwiftData(element)

            table.insert(accounts, {
                name = element:xpath(".//dd[@class='account-name']"):text(),
                --accountNumber = element:xpath(".//dd[@class='account-number']"):text(),
                --bankCode = element:xpath(".//dt[text()='Sort code']/following-sibling::dd[1]"):text(),
                owner = startPage:xpath("//span[@class='m-hf-02-name']"):text(),
                accountNumber = accountNumber,
                bankCode = sortCode,
                iban = iban,
                bic = bic,
                currency = "GBP",
                type = accountType
            })
        end
    )

  return accounts
end


function RefreshAccount(account, since)
    local statementPage = nil
    local balance = nil
    local accountIdentifier = nil
    local isCurrentAccount = false

    -- query balance & get statement url
    startPage:xpath("//div[@data-tracking-model='CurrentAccountTile' or @data-tracking-model='SavingsAccountTile']"):each(
        function(index, element)
            local accountNumber = element:xpath(".//dd[@class='account-number']"):text()

            if accountNumber == account.accountNumber then
                local balanceStr = element:xpath(".//p[@class='balance ManageMyAccountsAnchor2']/span"):text()
                balanceStr = string.gsub(balanceStr, "£ ", "")
                balanceStr = string.gsub(balanceStr, ",", "")
                balance = tonumber(balanceStr)
                
                accountIdentifier = element:attr("data-ajax-identifier")
                
                isCurrentAccount = element:attr("data-tracking-model") == "CurrentAccountTile"

                statementPage = clickHtml(element, ".//dd[@class='account-name']/a[1]")
                updateLogoutUrl(statementPage)
             end
        end
    )
    
    if statementPage == nil then
        error("Could retrieve statement")
    end

    local transactions = {}

    -- load pending transactions
    if isCurrentAccount then
        local apiPath = "/personal/retail/statement-api/browser/v1/arrangements/" .. accountIdentifier .. "/pendingTransactions"
        local data = JSON(connection:request("GET", apiPath, nil, nil, {Accept = "application/json"})):dictionary()
        
        for key, entry in pairs(data["pendingDebitCardTransactions"]["transactions"]) do
            table.insert(transactions, {
                bookingDate = apiDateStrToTimestamp(entry["date"]),
                purpose = entry["description"],
                amount = 0 - tonumber(entry["amount"]["amount"]),
                bookingText = entry["paymentType"],
                booked = false
            })        
        end
    end

    -- load transactions
    while statementPage ~= nil do
        updateLogoutUrl(statementPage)

        local transactionDetails = statementPage:xpath("//tbody[@class='transaction-details']")
        local lastTimestamp = 0

        transactionDetails:children():each(
            function(index, element)  
                local firstElement = element:children():get(1)
                local timestamp = humanDateStrToTimestamp(firstElement:text())
                local bookingCode = element:children():get(3):text()
                
                local transactionCode = nil
                local amount = nil
                
                if isCurrentAccount then
                    transactionCode = tonumber(firstElement:attr("transactionref"), 16)
                    amount = tonumber(firstElement:attr("amount"))
                else
                    transactionCode = nil
                    
                    local inAmountStr = element:children():get(4):text()
                    local outAmountStr = element:children():get(5):text()
                    local amountStr

                    if string.len(inAmountStr) > 0 then
                        amountStr = inAmountStr
                    else
                        amountStr = "-" .. outAmountStr
                    end
                    
                    amountStr = string.gsub(amountStr, ",", "")
                    amount = tonumber(amountStr)
                end

                table.insert(transactions, {
                    transactionCode = transactionCode,
                    bookingDate = timestamp,
                    purpose = beautifyDescription(element:children():get(2):text(), bookingCode),
                    amount = amount,
                    bookingText = lookupBookingCode(bookingCode)
                })

                lastTimestamp = timestamp
            end
        )


        local url = statementPage:xpath("(//a[@aria-label='Previous'])[1]"):attr("href")
        if string.len(url) > 0 then
            statementPage = HTML(connection:request("GET", url))
        else
            statementPage = nil
        end


        if lastTimestamp < since then
            break
        end
    end

    return {balance = balance, transactions = transactions}
end

-- lloyds bank helpers -------------------------------------------------------------------------------------------------

function updateLogoutUrl(page)
    local logoutButton = page:xpath("//a[@id='ifCommercial:ifCustomerBar:ifMobLO:outputLinkLogOut']")

    if logoutButton:length() == 1 then
        logoutUrl = logoutButton:attr("href")
    else
        print("can not update logout url")
    end
end

function getSwiftData(element)
    local statementPage = clickHtml(element, ".//dd[@class='account-name']/a[1]")
    updateLogoutUrl(statementPage)

    local data = JSON(connection:request("GET", statementPage:xpath("//a[@class='AccInfo_Anchor2']"):attr("data-ajax-uri"))):dictionary()

    return data["iban"], data["bic"], data["account-number"], data["sort-code"]
end

-- lloyds bank formatting helpers --------------------------------------------------------------------------------------

function humanDateStrToTimestamp(dateStr)
    local dayStr, monthStr, yearStr = string.match(dateStr, "(%d%d) (%u%l%l) (%d%d)")

    local monthDict = {
        Jan = 1,
        Feb = 2,
        Mar = 3,
        Apr = 4,
        May = 5,
        Jun = 6,
        Jul = 7,
        Aug = 8,
        Sep = 9,
        Oct = 10,
        Nov = 11,
        Dec = 12
    }

    return os.time({
        year = 2000 + tonumber(yearStr),
        month = monthDict[monthStr],
        day = tonumber(dayStr)
    })
end

function apiDateStrToTimestamp(dateStr)
    local yearStr, monthStr, dayStr = string.match(dateStr, "(%d%d%d%d)-(%d%d)-(%d%d)")

    return os.time({
        year = tonumber(yearStr),
        month = tonumber(monthStr),
        day = tonumber(dayStr)
    })
end

function lookupBookingCode(code)
    local dict = {
        BGC = "Bank Giro Credit (BGC)",
        BNS = "Bonus (BNS)",
        BP  = "Bill Payment (BP)",
        CHG = "Charge (CHG)",
        CHQ = "Cheque (CHQ)",
        COM = "Commission (COM)",
        COR = "Correction (COR)",
        CPT = "Cashpoint (CPT)",
        CSH = "Cash (CSH)",
        CSQ = "Cash/Cheque (CSQ)",
        DD  = "Direct Debit (DD)",
        DEB = "Debit Card (DEB)",
        DEP = "Deposit (DEP)",
        EFT = "EFTPOS (electronic funds transfer at point of sale) (EFT)",
        EUR = "Euro Cheque (EUR)",
        FE  = "Foreign Exchange (FE)",
        FEE = "Fixed Service Charge (FEE)",
        FPC = "Faster Payment charge (FPC)",
        FPI = "Faster Payment incoming (FPI)",
        FPO = "Faster Payment outgoing (FPO)",
        IB  = "Internet Banking (IB)",
        INT = "Interest (INT)",
        MPI = "Mobile Payment incoming (MPI)",
        MPO = "Mobile Payment outgoing (MPO)",
        MTG = "Mortgage (MTG)",
        NS  = "National Savings Dividend (NS)",
        NSC = "National Savings Certificates (NSC)",
        OTH = "Other (OTH)",
        PAY = "Payment (PAY)",
        PSB = "Premium Savings Bonds (PSB)",
        PSV = "Paysave (PSV)",
        SAL = "Salary (SAL)",
        SPB = "Cashpoint (SPB)",
        SO  = "Standing Order (SO)",
        STK = "Stocks/Shares (STK)",
        TD  = "Dep Term Dec (TD)",
        TDG = "Term Deposit Gross Interest (TDG)",
        TDI = "Dep Term Inc (TDI)",
        TDN = "Term Deposit Net Interest (TDN)",
        TFR = "Transfer (TFR)",
        UT  = "Unit Trust (UT)",
        SUR = "Excess Reject (SUR)"
    }

    return dict[code]
end

function beautifyDescription(description, bookingCode)
    if bookingCode == "DEB" or bookingCode == "CPT" then
        local startIndex, _, line1, line2 = string.find(description, "^(.*) (CD %d%d%d%d.*)$")

        if startIndex ~= nil then
            return line1 .. "\n" .. line2
        end
    end


    if bookingCode == "FPO" or bookingCode == "TFR" or bookingCode == "DD" or bookingCode == "FPI" then
        -- matches first word with more than five digits to second line
        local startIndex, _ = string.find(description, " %a*%d%d%d%d%d")

        if startIndex ~= nil then
            local line1 = string.sub(description, 0, startIndex - 1)
            local line2 = string.sub(description, startIndex + 1)
            return line1 .. "\n" .. line2
        end
    end

    return description
end

-- money money html helpers --------------------------------------------------------------------------------------------

function clickHtml(element, xpath)
    -- somehow :click() does not work. use url
    return HTML(connection:request("GET", element:xpath(xpath):attr("href")))
end

-- lua debug helpers ---------------------------------------------------------------------------------------------------

function printTable(table)
    for k, v in pairs(table) do
        print(k, v)
    end
end

