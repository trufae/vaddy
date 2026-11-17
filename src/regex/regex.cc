#include "regex.h"
#include <re2/re2.h>
#include <cstring>
#include <string>
#include <vector>

static RE2::Options regex_options() {
    RE2::Options options;
    options.set_log_errors(false);
    options.set_max_mem(8 << 20);
    return options;
}

extern "C" int vaddy_regex_valid(const char *pattern) {
    RE2 re(pattern, regex_options());
    return re.ok();
}

// Go regexp replacements use $name, ${name}, $1 and $$, unlike RE2's
// backslash substitution language. Expand captures without interpreting them
// again, and never allow a replacement to grow past the HTTP header bound.
static bool expand(const RE2 &re, const char *replacement,
                   const std::vector<re2::StringPiece> &groups,
                   std::string &out, size_t capacity) {
    std::string text(replacement);
    for (size_t i = 0; i < text.size();) {
        if (text[i] != '$') { out += text[i++]; }
        else if (i + 1 < text.size() && text[i + 1] == '$') { out += '$'; i += 2; }
        else {
            size_t start = i + 1;
            bool braces = start < text.size() && text[start] == '{';
            if (braces) ++start;
            size_t end = start;
            while (end < text.size()) {
                unsigned char c = text[end];
                if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') ||
                      (c >= 'A' && c <= 'Z') || c == '_' || c >= 128)) break;
                ++end;
            }
            if (end == start || (braces && (end == text.size() || text[end] != '}'))) {
                out += '$'; ++i; continue;
            }
            std::string name = text.substr(start, end - start);
            int index = -1;
            if (name.find_first_not_of("0123456789") == std::string::npos) {
                if (name.size() < 9 && (name.size() == 1 || name[0] != '0')) index = std::stoi(name);
            } else {
                auto found = re.NamedCapturingGroups().find(name);
                if (found != re.NamedCapturingGroups().end()) index = found->second;
            }
            if (index >= 0 && size_t(index) < groups.size() && groups[index].data())
                out.append(groups[index].data(), groups[index].size());
            i = end + (braces ? 1 : 0);
        }
        if (out.size() > capacity) return false;
    }
    return true;
}

extern "C" int vaddy_regex_replace(const char *pattern, const char *replacement,
                                    const char *input, char *output, int capacity) {
    try {
        RE2 re(pattern, regex_options());
        if (!re.ok() || re.NumberOfCapturingGroups() > 1024 || capacity < 0) return -1;
        re2::StringPiece source(input);
        std::vector<re2::StringPiece> groups(re.NumberOfCapturingGroups() + 1);
        std::string result;
        size_t search = 0, copied = 0;
        bool previous = false;
        while (search <= source.size() &&
               re.Match(source, search, source.size(), RE2::UNANCHORED, groups.data(), groups.size())) {
            size_t begin = groups[0].data() - source.data();
            size_t end = begin + groups[0].size();
            if (end != begin || !previous || begin != copied) {
                result.append(source.data() + copied, begin - copied);
                if (!expand(re, replacement, groups, result, capacity)) return -2;
                copied = end;
                previous = true;
            }
            if (result.size() > size_t(capacity)) return -2;
            search = end;
            if (end == begin) {
                if (search == source.size()) break;
                ++search;
                while (search < source.size() && (static_cast<unsigned char>(source[search]) & 0xc0) == 0x80) ++search;
            }
        }
        result.append(source.data() + copied, source.size() - copied);
        if (result.size() > size_t(capacity)) return -2;
        std::memcpy(output, result.data(), result.size());
        return int(result.size());
    } catch (...) { return -1; }
}
