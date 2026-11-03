/* SPDX-License-Identifier: BSD-3-Clause-Clear */
/* Actual source fragments precede this harness. No network or device API. */
int main(int argc, char **argv)
{
	static const u32 firmware_codes[] = { 0, 1, 2, 3, 4, 5, 6, UINT32_MAX };
	static const unsigned int initial_codes[] = { 0, 3, 99 };
	static const char *const names[] = {
		"REG_SET_CC_STATUS_PASS", "REG_CURRENT_ALPHA2_NOT_FOUND",
		"REG_INIT_ALPHA2_NOT_FOUND", "REG_SET_CC_CHANGE_NOT_ALLOWED",
		"REG_SET_CC_STATUS_NO_MEMORY", "REG_SET_CC_STATUS_FAIL"
	};
	const char *mode = argc == 2 ? argv[1] : "all";
	struct ath11k_base ab = { 0 };
	unsigned int cases = 0;
	bool check_warning = !strcmp(mode, "all") || !strcmp(mode, "warning");

	assert(!strcmp(mode, "all") || !strcmp(mode, "legacy") ||
	       !strcmp(mode, "extended") || !strcmp(mode, "warning") ||
	       !strcmp(mode, "values"));
	for (unsigned int event = 0; event < 2; event++) {
		for (unsigned int phy = 0; phy < 2; phy++) {
			for (size_t i = 0; i < sizeof(firmware_codes) / sizeof(firmware_codes[0]); i++) {
				for (size_t j = 0; j < sizeof(initial_codes) / sizeof(initial_codes[0]); j++) {
					struct cur_regulatory_info info, saved;
					u32 raw = firmware_codes[i];
					unsigned int expected = raw <= 5 ? raw : 5;
					bool check_debug = !strcmp(mode, "all") ||
						(!initial_codes[j] &&
						 ((!strcmp(mode, "legacy") && !event) ||
						  (!strcmp(mode, "extended") && event)));
					char fragment[80];
					int result;

					memset(&info, 0, sizeof(info));
					info.status_code = initial_codes[j];
					info.alpha2[0] = 'T';
					info.alpha2[1] = 'R';
					info.phy_id = phy;
					info.is_ext_reg_event = !event;
					debug_calls = warning_calls = 0;
					debug_text[0] = warning_text[0] = 0;
					if (event)
						actual_extended(&ab, &info, raw);
					else
						actual_legacy(&ab, &info, raw);
					assert((unsigned int)info.status_code == expected);
					assert(info.is_ext_reg_event == !!event);
					assert(debug_calls == 1);
					if (check_debug) {
						snprintf(fragment, sizeof(fragment), "status_code %s", names[expected]);
						assert(!strcmp(debug_text, fragment) &&
						       "WMI debug must describe the converted firmware event");
					}
					memcpy(&saved, &info, sizeof(saved));
					result = actual_refusal(&ab, &info);
					assert(result == (expected ? -EINVAL : 0));
					assert(warning_calls == !!expected);
					assert(!memcmp(&saved, &info, sizeof(info)));
					if (expected && check_warning) {
						assert(strstr(warning_text, names[expected]) &&
						       "Firmware refusal warning must expose the converted status");
						snprintf(fragment, sizeof(fragment), "(%u)", expected);
						assert(strstr(warning_text, fragment));
						snprintf(fragment, sizeof(fragment), "phy %u", phy);
						assert(strstr(warning_text, fragment));
						assert(strstr(warning_text, "alpha2 TR"));
						assert(strstr(warning_text, event ? "extended event" : "legacy event"));
					}
					cases++;
				}
			}
		}
	}
	assert(cases == 96);
	printf("Actual ath11k status blocks: %s PASS, %u cases; logging only, no radio operations\n", mode, cases);
	return 0;
}
