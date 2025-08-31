import os, io, psycopg2, boto3
from flask import Flask, request, send_file, jsonify
app = Flask(__name__)
S3_BUCKET = os.environ["S3_BUCKET"]
DB_HOST = os.environ["DB_HOST"]
DB_USER = os.environ["DB_USER"]
DB_PASS = os.environ["DB_PASS"]
DB_NAME = os.environ.get("DB_NAME", "appdb")
s3 = boto3.client("s3")
def db_conn(): return psycopg2.connect(host=DB_HOST, user=DB_USER, password=DB_PASS, dbname=DB_NAME)
@app.route("/up")
def up(): return ("OK", 200)
@app.route("/upload", methods=["POST"])
def upload():
    f = request.files.get("file")
    if not f: return ("no file", 400)
    key = f.filename
    s3.put_object(Bucket=S3_BUCKET, Key=key, Body=f.read())
    url = f"https://{S3_BUCKET}.s3.amazonaws.com/{key}"
    with db_conn() as con, con.cursor() as cur:
        cur.execute("CREATE TABLE IF NOT EXISTS uploads(name text primary key, ts timestamptz default now())")
        cur.execute("INSERT INTO uploads(name) VALUES(%s) ON CONFLICT DO NOTHING", (key,))
        cur.execute("SELECT count(*) FROM uploads")
        total = cur.fetchone()[0]
    return jsonify({"url": url, "uploads_in_db": total})
@app.route("/file/<name>")
def get_file(name):
    obj = s3.get_object(Bucket=S3_BUCKET, Key=name)
    return send_file(io.BytesIO(obj["Body"].read()), download_name=name)
