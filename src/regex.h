#ifndef VADDY_REGEX_H
#define VADDY_REGEX_H
#ifdef __cplusplus
extern "C" {
#endif
int vaddy_regex_valid(const char *pattern);
int vaddy_regex_replace(const char *pattern, const char *replacement,
                        const char *input, char *output, int capacity);
#ifdef __cplusplus
}
#endif
#endif
