from prodash.storage import auth_headers


def test_secret_key_goes_in_apikey_only():
    assert auth_headers("sb_secret_abc123") == {"apikey": "sb_secret_abc123"}


def test_legacy_jwt_key_goes_in_both_headers():
    key = "eyJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIn0.sig"
    assert auth_headers(key) == {"Authorization": f"Bearer {key}", "apikey": key}
