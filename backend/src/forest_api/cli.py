import argparse

from forest_api.auth import issue_development_token
from forest_api.config import Settings
from forest_api.database import Database
from forest_api.seed import seed_development_catalogue


def main() -> None:
    parser = argparse.ArgumentParser(description="Movement Forest development tools")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("seed-dev", help="Seed explicitly unapproved local/test catalogue")
    token = commands.add_parser("dev-token", help="Issue a local/test-only 30-minute token")
    token.add_argument("subject")
    args = parser.parse_args()
    settings = Settings()
    if args.command == "dev-token":
        print(issue_development_token(settings, args.subject))
        return
    database = Database(settings)
    try:
        with database.sessions() as session:
            seed_development_catalogue(session, settings)
        print("Development catalogue ready; all balance values are fixtures.")
    finally:
        database.engine.dispose()


if __name__ == "__main__":
    main()
