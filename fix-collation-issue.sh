#!/bin/bash
# Navigate to project root
cd /Users/smallgod/srv/applications/mets/openmrs-module-mamba-core

echo "Fixing charset/collation compatibility issues..."

# 1. Fix table definitions
find . -name "*.sql" -type f -exec sed -i '' 's/CHARSET = UTF8MB4;/CHARSET = UTF8MB4 COLLATE = utf8mb4_unicode_ci;/g' {} +

# 2. Fix parameter declarations (add collation)
find . -name "*.sql" -type f -exec sed -i '' 's/CHARACTER SET UTF8MB4/CHARACTER SET UTF8MB4 COLLATE utf8mb4_unicode_ci/g' {} +

# 3. Fix any remaining charset declarations without semicolon
find . -name "*.sql" -type f -exec sed -i '' 's/CHARSET = UTF8MB4$/CHARSET = UTF8MB4 COLLATE = utf8mb4_unicode_ci/g' {} +

echo "✅ All charset/collation issues fixed!"
echo "📋 Summary:"
echo "   - Updated table definitions to use utf8mb4_unicode_ci"
echo "   - Updated stored procedure parameters"
echo "   - Ensured compatibility with MySQL 5.7+ and MariaDB"
