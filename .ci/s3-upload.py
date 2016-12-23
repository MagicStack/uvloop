#!/usr/bin/env python3


import argparse
import glob
import os
import os.path
import sys

import tinys3


def main():
    parser = argparse.ArgumentParser(description='S3 File Uploader')
    parser.add_argument(
        '--s3-bucket',
        help=('S3 bucket name (defaults to $S3_UPLOAD_BUCKET)'),
        default=os.environ.get('S3_UPLOAD_BUCKET'))
    parser.add_argument(
        '--s3-region',
        help=('S3 region (defaults to $S3_UPLOAD_REGION)'),
        default=os.environ.get('S3_UPLOAD_REGION'))
    parser.add_argument(
        '--s3-username',
        help=('S3 username (defaults to $S3_UPLOAD_USERNAME)'),
        default=os.environ.get('S3_UPLOAD_USERNAME'))
    parser.add_argument(
        '--s3-key',
        help=('S3 access key (defaults to $S3_UPLOAD_ACCESSKEY)'),
        default=os.environ.get('S3_UPLOAD_ACCESSKEY'))
    parser.add_argument(
        '--s3-secret',
        help=('S3 secret (defaults to $S3_UPLOAD_SECRET)'),
        default=os.environ.get('S3_UPLOAD_SECRET'))
    parser.add_argument(
        'files', nargs='+', metavar='FILE', help='Files to upload')

    args = parser.parse_args()

    if args.s3_region:
        endpoint = 's3-{}.amazonaws.com'.format(args.s3_region.lower())
    else:
        endpoint = 's3.amazonaws.com'

    conn = tinys3.Connection(
        access_key=args.s3_key,
        secret_key=args.s3_secret,
        default_bucket=args.s3_bucket,
        tls=True,
        endpoint=endpoint,
    )

    for pattern in args.files:
        for fn in glob.iglob(pattern):
            with open(fn, 'rb') as f:
                conn.upload(os.path.basename(fn), f)

    return 0


if __name__ == '__main__':
    sys.exit(main())
