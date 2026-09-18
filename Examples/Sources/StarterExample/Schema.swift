//===----------------------------------------------------------------------===//
// The schema, as an append-only list of migrations.
//
// Rules that keep this workable:
//
// - Append. Never edit or delete a migration that has run: the database
//   records how many have been applied, and an edited one will not run again.
// - One migration is the statements that belong together. They run in one
//   transaction, so a migration either happened or did not.
// - Times are stored as epoch seconds (bigint). PostgreSQL's timestamptz has
//   no Swift type of its own yet (CONNECTORS.md), and a number decodes into
//   `Int64` everywhere without a format to agree on.
// - The refresh-token tables come from Garuda, so they are migrated with
//   everything else rather than created on the side.
//===----------------------------------------------------------------------===//

import Garuda

public let starterMigrations: [[String]] = [
    // 1: accounts.
    [
        """
        create table users (
            id bigserial primary key,
            email text not null unique,
            password text not null,
            created_at bigint not null)
        """,
    ],
    // 2: what the accounts own.
    [
        """
        create table notes (
            id bigserial primary key,
            user_id bigint not null references users (id) on delete cascade,
            title text not null,
            body text not null default '',
            created_at bigint not null,
            updated_at bigint not null)
        """,
        "create index notes_user_id on notes (user_id, id desc)",
    ],
    // 3: refresh tokens, Garuda's own tables.
    PostgresRefreshTokenStore.schema(),
]
