"""Upload / list / download a DRIM package against an S3 endpoint (Garage here)."""
import os, sys, hashlib, boto3
from botocore.config import Config

ep     = os.environ["S3_ENDPOINT"]
bucket = os.environ.get("S3_BUCKET", "drim-packages")
s3 = boto3.client("s3", endpoint_url=ep,
                  aws_access_key_id=os.environ["AWS_ACCESS_KEY_ID"],
                  aws_secret_access_key=os.environ["AWS_SECRET_ACCESS_KEY"],
                  region_name=os.environ.get("AWS_DEFAULT_REGION", "garage"),
                  config=Config(s3={"addressing_style": "path"}))

def put(pkg, rev):
    for root, _, files in os.walk(pkg):
        for f in sorted(files):
            local = os.path.join(root, f)
            key = f"{rev}/" + os.path.relpath(local, pkg)
            s3.upload_file(local, bucket, key)
            print(f"  PUT  {os.path.getsize(local):>10}  s3://{bucket}/{key}")

def ls(prefix=""):
    total = n = 0
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket, Prefix=prefix):
        for o in page.get("Contents", []):
            print(f"  {o['Size']:>10}  {o['LastModified']:%Y-%m-%d %H:%M}  {o['ETag'].strip(chr(34))[:12]}…  s3://{bucket}/{o['Key']}")
            total += o["Size"]; n += 1
    print(f"  ---- {n} objects, {total} bytes total ----")

def get(rev, dest):
    os.makedirs(dest, exist_ok=True)
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket, Prefix=rev + "/"):
        for o in page.get("Contents", []):
            rel = o["Key"][len(rev) + 1:]
            p = os.path.join(dest, rel)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            s3.download_file(bucket, o["Key"], p)
            print(f"  GET  {os.path.getsize(p):>10}  {rel}")

def presign(key, secs=3600):
    print(s3.generate_presigned_url("get_object", Params={"Bucket": bucket, "Key": key}, ExpiresIn=secs))

cmd = sys.argv[1]
{"put": lambda: put(sys.argv[2], sys.argv[3]),
 "ls": lambda: ls(sys.argv[2] if len(sys.argv) > 2 else ""),
 "get": lambda: get(sys.argv[2], sys.argv[3]),
 "presign": lambda: presign(sys.argv[2])}[cmd]()
