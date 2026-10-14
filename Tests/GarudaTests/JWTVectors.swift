// Tokens and keys made by PyJWT 2.14 with the cryptography package, to check
// that what another implementation signs verifies here.

enum PyJWTVectors {
    static let rsaPublic = """
        -----BEGIN PUBLIC KEY-----
        MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAuudXyli2bfW8zcY0yh9o
        PNRxWDvXPuo9EZS2lBUeKTXyLWJnhG3QNtlp1LWSMnwNyR/etDy+40ZKcDuBkIyq
        vvGuRfuRz9VguCvJ7uLEns/A03GZCNWgDT1P0kVuTaXLA/VdMqxXfaii7LR61lZv
        pjvKkMzeoaRjIDzuGfopETpDjGruExEKVbdfdn4l+f1zfDWWkXJyvBr9sM9mrZtF
        sP1BbPM5qoRGb12rRwjwEA8XvtcSyzSUfUR3KRyzYHGkjwEU0JzOceJZofsdKk3T
        c5wqqiA6jnczd1OG4uorn5obO47JZ3xpUlbGS3M/i/GDcORpmFUQQUtFr6zUDJX3
        wwIDAQAB
        -----END PUBLIC KEY-----
        """
    static let ec256Public = """
        -----BEGIN PUBLIC KEY-----
        MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEzijKlYMqR/1UAy1k70W2igUOtpCW
        WfKOfeIASj0DuDP7qUsZwuakTDpOJoh+whh+DeFh1m9DbeXqj0N/8yA6oQ==
        -----END PUBLIC KEY-----
        """
    static let ec384Public = """
        -----BEGIN PUBLIC KEY-----
        MHYwEAYHKoZIzj0CAQYFK4EEACIDYgAE2IfX6uyKZOHUqjU2ghL3QfNh9KqG27zM
        7VtcEdNzcTjm8AykF4RZUJLkBSOuj6ElP2vzu5Tu7kfMJqzYMOPNKk2YnWjppyyC
        wVrl5xW1l3eIPIXCyEABULvXiQAWg30Z
        -----END PUBLIC KEY-----
        """
    static let ec521Public = """
        -----BEGIN PUBLIC KEY-----
        MIGbMBAGByqGSM49AgEGBSuBBAAjA4GGAAQAMGvDqumkm6FWWwz/o1rDXUxnhW8U
        SmjxnPsBLBEGGGOdvnel9Ie2oh/NsuT3UfW4FwlSmDoSNihGErEA5OCvz5sBd6K4
        TYjj9Jp1oElJ3DSBzNvJEkYOoFEuIAogWouZcK0MI2q1727Gj7fiGuVx/4c6XCxi
        3Tn+GLvMJp09Zr3CeRg=
        -----END PUBLIC KEY-----
        """
    static let edPublic = """
        -----BEGIN PUBLIC KEY-----
        MCowBQYDK2VwAyEA4Anco2bpyBPyXtZ3HahS6O4yr5ihQlxxEvOAMn7kVlk=
        -----END PUBLIC KEY-----
        """
    static let smallRSAPublic = """
        -----BEGIN PUBLIC KEY-----
        MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDvJf81F26KJ8YuKaWRGKVdNlnZ
        ZH/PhoGK6V4cBncP7xR/tptlfK24XVsOpo/hvAnhWCYsrS7ragWOFWlrxDRiHm94
        T0N/fOknRZIMVCBi0gbKcUL//Q6j4RkyFuxVTd2ARL7hjjzll83ZeQxWrlnWmKM7
        t+IyZwNYMhPZIZ6JmwIDAQAB
        -----END PUBLIC KEY-----
        """
    static let RS256 = "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiI0MiIsInJvbGUiOiJhZG1pbiIsImV4cCI6NDEwMjQ0NDgwMCwiaXNzIjoicHlqd3QiLCJhdWQiOlsic2hvcCIsIm90aGVyIl19.VKsPP5Zo4Z8UaHBbMBU9oPha4KjEVKNJ1DhLt5rQr07ErWAWTuN7asjo8yO5LKxfF-K-Gjc8UhhhRmC8Z_g6SFZ9i5i4-Pr6UIQVAHdfFbu-qLh6DbgTaZQfJOVFUw1XlrJQeORdCXGteOVLgIXH8Oc7aTNlPXhuiGyXfy19oHrMGA9Fs6rmYECMUNmeqhhAN8hpaK-zWfxgIEWqqXHcyn22GvFb1BhM055s7bqIwF7tqO-R4i8Ut2JRVwNkQ3lcLpZXx55yWVXpLb4ZQLJXw4hFO9AYBuI4v7LqZ9FFscqDH0KnMmH8cNOEhLunEw22E0AFT1am5SuRTe2ONJoiKw"
    static let RS384 = "eyJhbGciOiJSUzM4NCIsInR5cCI6IkpXVCJ9.eyJzdWIiOiI0MiIsInJvbGUiOiJhZG1pbiIsImV4cCI6NDEwMjQ0NDgwMCwiaXNzIjoicHlqd3QiLCJhdWQiOlsic2hvcCIsIm90aGVyIl19.XGM22OipZT4PdES09jDbgTAX_MP1dteRSXzd6e5vUIkSKae7toGq5gGXowLxwGUo_JjAyIXiJGPMNB2tUB2DazrV0lNWnBqFYCuHnOX8CuqE736kfPN82D99tkX8Sh99tBdSIeLnXP5lqanJnTwGEu0QZHU0bMB28hd7yhxykezbdOy_h8Z8o9Fj_md2UJJbeXR5Q-XD74aMdJyMWq3KnyZ7nS-YvvAcQFwL84-FKxmUyFbdCSkXj5qp1uv8OBWm6F78QCxDUgSS2F_XKHXwi6lVXYaXMAUBCRWg2opT0g4XVIvarVUJh4Qp4kCH7b7meS9LpWEAVwZUqkexlcP9Rg"
    static let RS512 = "eyJhbGciOiJSUzUxMiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiI0MiIsInJvbGUiOiJhZG1pbiIsImV4cCI6NDEwMjQ0NDgwMCwiaXNzIjoicHlqd3QiLCJhdWQiOlsic2hvcCIsIm90aGVyIl19.nafnAtZy4tXnEqTRjvNu-8IzR9s8T6AaqkmQqmyVBbJloioMC9Eierxrci-JQ9-Ad_s082oMZzoJlktVTZihKMtv90pJ9DAndn5rj6E_17QdqqfKxxDhks0xKO6PuJnkheKF8ZCyRyhc-hCcerdeOSn5ItN-IGjSHb-PLKjoEN3vlP811KkqTBfaQ-3GGA7aPudOjts5MJ2-GBrXKdFxw9sMeJ-layH5nQehQ26mdTcrgaookT3XGMaiNIiEJm8mxyUHZ4hP7MACE1uCFJJjQoP_S2BmpGZYFa_lorraAvM4Yrn8FYa7GsnVvw7JzpoXn1nSOb0BDZVRAUWPDwC73g"
    static let PS256 = "eyJhbGciOiJQUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiI0MiIsInJvbGUiOiJhZG1pbiIsImV4cCI6NDEwMjQ0NDgwMCwiaXNzIjoicHlqd3QiLCJhdWQiOlsic2hvcCIsIm90aGVyIl19.KRgShUqkZet7TFHfHuchhiq47-BrmArtIsmCCmaKvwQlCxfAwmNpJTWpkPVwc5j5xa9JrPanWelcvcQ8d4OWc8dbIdGbcNc4XctBsvhqNCEm7vHrq4PPF6hj_5PDsIbtFhQNOlq8XaOljnMo9J8Bn9D0dMxCD_0V8WnYVEl-rHRsK1_hBq920Efa-tOWbf4ie6gXgPum54hMj2vTqh4IE-e0LBAVgVAmqFUc8u4gZ15L5D6tzAIgEM8e-yx4iFK0Xw-TenLjr_UhF_KSD0caK-wOxxMDgHkG5txLEaKhF01AppF2qCmirmUBp2hTJ4dtKgQY7P5TTuFhEwoAwsDkuA"
    static let PS384 = "eyJhbGciOiJQUzM4NCIsInR5cCI6IkpXVCJ9.eyJzdWIiOiI0MiIsInJvbGUiOiJhZG1pbiIsImV4cCI6NDEwMjQ0NDgwMCwiaXNzIjoicHlqd3QiLCJhdWQiOlsic2hvcCIsIm90aGVyIl19.CqNVk5sc2z70qfB-cVr-G495KQIYGMt8ej_BiqWBxdtfxPV7XD2ewH-g3Y5ncSopoEavF6tKiTAVnLv6iI4S8wI_0BhAe3TpNPZrRI4QgB_QtjGtpBzTNl4n94WCJ4_j2-ufXXzLXsykMEf0Rs6bxHvtRBXof0dmYQ5_KNLzJmaDmIGu9q_BKU4rnC7laHhURJGBOOnnUWAuA4C3yWhpbYgNKOOJf3ResSjJiQKHc0k9G6-H1P5Ovry9R_GCpKDTx-C0CTcyI5pFas1GT0TduPownQ_NoI5u4XZ9jnH_ACi5zI-U9j3x2DmewSUz8GqkyOWYX01sp8V5wKeypz6SrQ"
    static let PS512 = "eyJhbGciOiJQUzUxMiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiI0MiIsInJvbGUiOiJhZG1pbiIsImV4cCI6NDEwMjQ0NDgwMCwiaXNzIjoicHlqd3QiLCJhdWQiOlsic2hvcCIsIm90aGVyIl19.fDqgaOUne8avelivLspVZ4NMwp6PzcvPm-s7755-3RSPOuolqY2p2GTKXIOKuJ3vxeYRgchZYnwU5wQoLG9BUhTvppKd7obzQX92iNVomtm7iSnFLYYatCOBE2kq-TPKIxX-qTgnvm_wrdf-O5WuyixghD85jWOlBcg4oZOzVHwadaJUEJBnunvmL3nFGuq5SkUeW86OeLtmipP1stslfjP88w9nubzA63gvOjgL2yiLy7uNNstwKaLCI1re4Rqcep-cGAYVrf3OzGSiWNMSOOTHiCNWL_-QowEapGlpaAB_OndDYeLlBj-KhkDdJlnUhUHefkLUbR8laPwxmN8e-g"
    static let ES256 = "eyJhbGciOiJFUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiI0MiIsInJvbGUiOiJhZG1pbiIsImV4cCI6NDEwMjQ0NDgwMCwiaXNzIjoicHlqd3QiLCJhdWQiOlsic2hvcCIsIm90aGVyIl19.hfpjUO7G7zKiRLnuWfGaXrEfHUs6k7Ca4XRKcNeVDGwcvuboFH3wqspxzfvtwxYZeesSpDIGf2vzKozQJ0cLTg"
    static let ES384 = "eyJhbGciOiJFUzM4NCIsInR5cCI6IkpXVCJ9.eyJzdWIiOiI0MiIsInJvbGUiOiJhZG1pbiIsImV4cCI6NDEwMjQ0NDgwMCwiaXNzIjoicHlqd3QiLCJhdWQiOlsic2hvcCIsIm90aGVyIl19.xBN_pN4ew_uLpqQ6p5fH88AikKzff_x8DfH1fsSuVtOajqL5USbj8e1JcaIdHWZeNMO4qJ4yI2IOWxFi44ASs5H4QgvfxJXY-xEGzMjpUx99U7Djuz8DHilcBamYoYLR"
    static let ES512 = "eyJhbGciOiJFUzUxMiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiI0MiIsInJvbGUiOiJhZG1pbiIsImV4cCI6NDEwMjQ0NDgwMCwiaXNzIjoicHlqd3QiLCJhdWQiOlsic2hvcCIsIm90aGVyIl19.AWNHIvFRI33_WlqPiwgADK49SvPrAV2iK9kXEekWyeP8d9VEDq6Fn9U5redhZJQJzG_It8jafiUk4cn_GUqLu4EpAE5DFg4lJY68JPgkbQI-t9cR45MazWvqUyg0XAHra07XK4QzO2_iHmFKnQmigb-FgOtwkjVlU3PT9nsjM1x6sV0M"
    static let EdDSA = "eyJhbGciOiJFZERTQSIsInR5cCI6IkpXVCJ9.eyJzdWIiOiI0MiIsInJvbGUiOiJhZG1pbiIsImV4cCI6NDEwMjQ0NDgwMCwiaXNzIjoicHlqd3QiLCJhdWQiOlsic2hvcCIsIm90aGVyIl19.rqlZfVKLuWMRrXvoD0AoukKCHyXdI_i6BvLTFfuJ7iQBdOoXvKN-LG6u8T4sHLE8VC9jIlsjOcIqv2KWUCG5DQ"
    static let HS256 = "eyJhbGciOiJIUzI1NiIsImtpZCI6InNoYXJlZCIsInR5cCI6IkpXVCJ9.eyJzdWIiOiI0MiIsInJvbGUiOiJhZG1pbiIsImV4cCI6NDEwMjQ0NDgwMCwiaXNzIjoicHlqd3QiLCJhdWQiOlsic2hvcCIsIm90aGVyIl19.lJOQqQWupGeL7bLc555oXqgUEFRr5GYgaDOZ2rfkChc"
    static let HS384 = "eyJhbGciOiJIUzM4NCIsImtpZCI6InNoYXJlZCIsInR5cCI6IkpXVCJ9.eyJzdWIiOiI0MiIsInJvbGUiOiJhZG1pbiIsImV4cCI6NDEwMjQ0NDgwMCwiaXNzIjoicHlqd3QiLCJhdWQiOlsic2hvcCIsIm90aGVyIl19.JjTaQH9nBEOB7AnZ9jBxz_mNDBauNBQNXso0Fo6r_hKKnhH6DnTJToUM11C8mxNa"
    static let HS512 = "eyJhbGciOiJIUzUxMiIsImtpZCI6InNoYXJlZCIsInR5cCI6IkpXVCJ9.eyJzdWIiOiI0MiIsInJvbGUiOiJhZG1pbiIsImV4cCI6NDEwMjQ0NDgwMCwiaXNzIjoicHlqd3QiLCJhdWQiOlsic2hvcCIsIm90aGVyIl19.FsKSp3Ej6kG1FDnwlRt3Sb5el1IPQhHLSvUzwJkBvMirBsOTLepl6T8TJUOuLXpF1bQFpAzHKtDq0YMNTe883w"
    static let rsaJWK = JWKParts(kty: "RSA", n: "uudXyli2bfW8zcY0yh9oPNRxWDvXPuo9EZS2lBUeKTXyLWJnhG3QNtlp1LWSMnwNyR_etDy-40ZKcDuBkIyqvvGuRfuRz9VguCvJ7uLEns_A03GZCNWgDT1P0kVuTaXLA_VdMqxXfaii7LR61lZvpjvKkMzeoaRjIDzuGfopETpDjGruExEKVbdfdn4l-f1zfDWWkXJyvBr9sM9mrZtFsP1BbPM5qoRGb12rRwjwEA8XvtcSyzSUfUR3KRyzYHGkjwEU0JzOceJZofsdKk3Tc5wqqiA6jnczd1OG4uorn5obO47JZ3xpUlbGS3M_i_GDcORpmFUQQUtFr6zUDJX3ww", e: "AQAB")
    static let ec256JWK = JWKParts(kty: "EC", crv: "P-256", x: "zijKlYMqR_1UAy1k70W2igUOtpCWWfKOfeIASj0DuDM", y: "-6lLGcLmpEw6TiaIfsIYfg3hYdZvQ23l6o9Df_MgOqE")
    static let edJWK = JWKParts(kty: "OKP", crv: "Ed25519", x: "4Anco2bpyBPyXtZ3HahS6O4yr5ihQlxxEvOAMn7kVlk")
}

struct JWKParts { var kty: String; var crv: String? = nil; var n: String? = nil; var e: String? = nil; var x: String? = nil; var y: String? = nil }
