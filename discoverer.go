package mpy6a

import "context"

// Discoverer абстракция поиска узлов кластера
type Discoverer func(ctx context.Context)
