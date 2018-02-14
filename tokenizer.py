def tokenize(user_string):
    result = []
    is_in_quote = False
    temp_string = []

    for s in user_string.replace('"',' " ').replace('?','').split():
        if '"' in s:
            temp_string.append(s)
            if is_in_quote:
                result.append(' '.join([ str(c).replace('"','') for c in temp_string if c != '"']))
                temp_string = []
            else:
                is_in_quote = True
        else:
            if is_in_quote:
                temp_string.append(s)
            else:
                result.append(s)

    if len(temp_string) > 0:
        for s in [ str(c).replace('"','') for c in temp_string if c != '"']:
            result.append(s)

    return result

if __name__=="__main__":
    r = tokenize('This is a string         with quotes around part" and some more quoted text"')
    print(r)
