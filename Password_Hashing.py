import hashlib

print("Enter String to Hash with random hashing algorithm...")
mystring = input()

hash = hashlib.sha256(mystring.encode()).hexdigest()

print(hash)