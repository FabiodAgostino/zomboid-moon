-- AutoPilot (Moon): automations for the Moon server.

AutoPilotMoon = AutoPilotMoon or {};

-- data handling

function AutoPilotMoon:isFunction(var)
    return type(var) == "function";
end

function AutoPilotMoon:ucFirst(srcString)
    -- one value only (gsub returns two)
    return (string.gsub(srcString, "^%l", string.upper));
end

function AutoPilotMoon:concatArrays(array1, array2)
	if not array2
	then
		return array1;
	end

	for i, item in ipairs(array2)
	do
		table.insert(array1, item);
	end

	return array1;
end
