#!/usr/bin/env python3


import argparse
import json
import requests
import re


BASE_URL = 'https://api.github.com/repos/magicstack/uvloop/compare'


def main():
    parser = argparse.ArgumentParser(
        description='Generate release log.')
    parser.add_argument('--to', dest='to_hash', default='master', type=str)
    parser.add_argument('--from', dest='from_hash', type=str)
    args = parser.parse_args()

    r = requests.get(f'{BASE_URL}/{args.from_hash}...{args.to_hash}')
    data = json.loads(r.text)

    for commit in data['commits']:
        message = commit['commit']['message']
        first_line = message.partition('\n\n')[0]
        if commit.get('author'):
            username = '@{}'.format(commit['author']['login'])
        else:
            username = commit['commit']['author']['name']
        sha = commit["sha"][:8]

        m = re.search(r'\#(?P<num>\d+)\b', message)
        if m:
            issue_num = m.group('num')
        else:
            issue_num = None

        print(f'* {first_line}')
        print(f'  (by {username} in {sha}', end='')
        if issue_num:
            print(f' for #{issue_num})')
        else:
            print(')')
        print()


if __name__ == '__main__':
    main()
