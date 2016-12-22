function RefreshAccount (account, since)
    local isFirst = true
    local transactions = {}    

    -- load transactions
    repeat
        local url = "https://secure.lloydsbank.co.uk/personal/link/lp_statement_ajax?_=" .. os.time() .. "&viewstatement=" .. (isFirst == true and "latest" or "previous")
        isFirst = false

        local data = JSON(getJSON()):dictionary()
        local transactionsData = data["transactions"]["items"]

        local lastTimestamp = 0

        for _, v in pairs(transactionsData) do
            local timestamp = dateStrToTimestamp(v["date"])

            table.insert(transactions, {
                transactionCode = tonumber(v["id"], 16),
                bookingDate = timestamp,
                purpose = table.concat(v["completeDescription"], "\n"),
                amount = v["amount"]["amount"],
                bookingText = v["paymentTypeForPanel"]
            })

            lastTimestamp = timestamp
        end

        -- repeat if we need more entries.
        -- this also finished if there is no more data to load,
        -- because lastTimestamp = 0 is smaller than since        
    until lastTimestamp < since

    return {balance=42.00, transactions=transactions}
end

function dateStrToTimestamp(dateStr)
    local yearStr, monthStr, dayStr, hourStr, minStr, secStr = string.match(dateStr, "(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)")

    return os.time({
        year = tonumber(yearStr),
        month = tonumber(monthStr),
        day = tonumber(dayStr),
        hour = tonumber(hourStr), 
        min = tonumber(minStr),
        sec = tonumber(secStr)
    })
end