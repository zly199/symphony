# kyuyo-backend Style Rules (from README.md)

Use these rules as mandatory review checks when reviewing `kyuyo-backend`.

## Scope

Source:
- `/Users/user/IdeaProjects/kyuyo-backend/README.md`
- Section: `開発スタイル` and `単体テストコード仕様`

## Mandatory checks

1. API design
- REST API URL must be lowercase and kebab-case (words connected by `-`).
- Implemented REST APIs must update Swagger/OpenAPI 3.0 spec.

2. Layering and responsibility
- Keep clear separation across Controller / Service / DAO / DTO.
- Controller must do permission check and minimum input validation.
- Service must hold business logic and data consistency checks.

3. Tests
- New or changed Service/Controller/DAO code must include corresponding unit tests.
- Test code must not mutate shared readonly base/sample data without restoration.
- Prefer purge-based cleanup for generated test data when applicable.

4. Documentation comments
- Public methods/properties require corresponding comments.
- For review comments, prioritize missing public API/method comments as style findings.

5. Migration TODO policy
- Migration-temporary logic must include TODO comment with ticket, for example:
  `// TODO: データ移行完了後削除、SC_SAAS-12345 【backend】XXXデータ移行削除`

6. Multi-tenant safety
- Verify host/company context handling is explicit when reading/writing tenant data.
- Flag missing tenant context propagation as high-risk even when P3C does not report it.

## Review severity mapping

- `High`: Security/data isolation risk, missing tenant guard, missing critical validation.
- `Medium`: Missing tests for changed business logic, OpenAPI not updated for API change.
- `Low`: Naming/style/comment inconsistencies that do not change runtime behavior.

## Output expectation

When reporting review:
- Split findings into `P3C findings` and `kyuyo-backend style findings`.
- Include exact file:line and concrete fix proposal.
