#!/bin/bash
# Navigate to project root
cd /Users/smallgod/srv/applications/mets/openmrs-module-mamba-core

echo "Removing explicit charset/collation definitions from SQL files..."
echo "Tables will now inherit charset/collation from database defaults."

# 1. Remove table-level charset definitions (with collation)
find . -name "*.sql" -type f -exec sed -i '' 's/CHARSET = UTF8MB4 COLLATE = utf8mb4_unicode_ci;//g' {} +
find . -name "*.sql" -type f -exec sed -i '' 's/) CHARSET = UTF8MB4 COLLATE = utf8mb4_unicode_ci;/);/g' {} +

# 2. Remove table-level charset definitions (without collation)
find . -name "*.sql" -type f -exec sed -i '' 's/CHARSET = UTF8MB4;//g' {} +
find . -name "*.sql" -type f -exec sed -i '' 's/) CHARSET = UTF8MB4;/);/g' {} +

# 3. Remove charset without semicolon (for temporary tables)
find . -name "*.sql" -type f -exec sed -i '' 's/CHARSET = UTF8MB4 AS/ AS/g' {} +
find . -name "*.sql" -type f -exec sed -i '' 's/)CHARSET = UTF8MB4 AS/) AS/g' {} +

# 3a. Remove charset on separate lines (like in CREATE...SELECT statements)
find . -name "*.sql" -type f -exec sed -i '' '/^[[:space:]]*CHARSET = UTF8MB4 COLLATE = utf8mb4_unicode_ci[[:space:]]*$/d' {} +
find . -name "*.sql" -type f -exec sed -i '' '/^[[:space:]]*CHARSET = UTF8MB4[[:space:]]*$/d' {} +

# 4. Remove UTF8MB3 charset (legacy)
find . -name "*.sql" -type f -exec sed -i '' 's/CHARSET = UTF8MB3;//g' {} +
find . -name "*.sql" -type f -exec sed -i '' 's/) CHARSET = UTF8MB3;/);/g' {} +

# 5. Remove parameter-level charset definitions (keep parameters but remove charset)
find . -name "*.sql" -type f -exec sed -i '' 's/CHARACTER SET UTF8MB4 COLLATE utf8mb4_unicode_ci//g' {} +
find . -name "*.sql" -type f -exec sed -i '' 's/CHARACTER SET UTF8MB4//g' {} +
find . -name "*.sql" -type f -exec sed -i '' 's/CHARSET UTF8MB4//g' {} +

# 6. Clean up any double spaces left behind
find . -name "*.sql" -type f -exec sed -i '' 's/  / /g' {} +

# 7. Clean up trailing spaces before closing parentheses
find . -name "*.sql" -type f -exec sed -i '' 's/ )/)/g' {} +

echo "✅ All explicit charset/collation definitions removed!"
echo "📋 Summary:"
echo "   - Tables will inherit charset/collation from database"
echo "   - Cleaner, more maintainable SQL code"
echo "   - Database-level defaults ensure consistency"
echo ""
echo "🔍 Checking for any remaining charset references..."
remaining=$(grep -r "CHARSET\|CHARACTER SET\|COLLATE" . --include="*.sql" | grep -v "fix-collation-issue.sh" | grep -v "cleanup-charset-definitions.sh" | wc -l)
echo "Found $remaining remaining charset references (excluding scripts)"

if [ $remaining -gt 0 ]; then
    echo ""
    echo "📋 Remaining references:"
    grep -r "CHARSET\|CHARACTER SET\|COLLATE" . --include="*.sql" | grep -v "fix-collation-issue.sh" | grep -v "cleanup-charset-definitions.sh" | head -5
fi
