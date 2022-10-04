package storage

import "github.com/sirkon/mpy6a/internal/types"

func newRBTree() *rbTree {
	return &rbTree{}
}

type rbTree struct {
	root *rbTreeNode
	size int
}

// savedSessionsData структура данных сохранённых сессий с повтором в заданное время
type savedSessionsData struct {
	Repeat   uint64
	Sessions []types.Session
}

// Iter отдача итератора по дереву.
func (t *rbTree) Iter() *rbTreeIterator {
	return &rbTreeIterator{
		r: t.root,
	}
}

// Len возвращает текущую длину дерева.
func (t *rbTree) Len() int {
	return t.size
}

// Min возвращает сессии начинающиеся раньше всех.
func (t *rbTree) Min() (val *savedSessionsData, exists bool) {
	if t.root == nil {
		return val, false
	}

	cur := t.root
	for cur.left != nil {
		cur = cur.left
	}

	return cur.value, true
}

// Clone предположительно быстрое создание копии дерева.
func (t *rbTree) Clone() *rbTree {
	values := make([]savedSessionsData, t.size)
	nodes := make([]rbTreeNode, t.size)
	mapping := make(map[*rbTreeNode]*rbTreeNode, t.size)
	var arenaIndex int

	iter := t.Iter()
	for iter.Next() {
		var p *rbTreeNode
		var l *rbTreeNode
		var r *rbTreeNode
		var n *rbTreeNode

		isRight := iter.n.isRight()
		if isRight {
			p, arenaIndex = rbTreeAllocNode(mapping, nodes, values, iter.n, arenaIndex)
		}

		l, arenaIndex = rbTreeAllocNode(mapping, nodes, values, iter.n.left, arenaIndex)
		n, arenaIndex = rbTreeAllocNode(mapping, nodes, values, iter.n, arenaIndex)
		r, arenaIndex = rbTreeAllocNode(mapping, nodes, values, iter.n.right, arenaIndex)

		if !isRight {
			p, arenaIndex = rbTreeAllocNode(mapping, nodes, values, iter.n.parent, arenaIndex)
		}

		n.left = l
		n.right = r
		n.parent = p
	}

	return &rbTree{
		root: mapping[t.root],
		size: t.size,
	}
}

// DeleteSessions удаляет сессии с повтором в заданное время.
// Возвращаемый true означает что элемент существовал и был удалён,
// а false — элемент не найден.
func (t *rbTree) DeleteSessions(repeat uint64) (deleted bool) {
	n := rbTreeLookupForValue(t.root, repeat)
	if n == nil {
		return false
	}

	p := n.parent
	defer func() {
		// очищаем связи для уменьшения нагрузки на GC
		n.parent = nil
		n.left = nil
		n.right = nil
		n = nil
		p = nil

		if deleted {
			t.size--
		}
	}()

	isRight := n.isRight()

	if n.left != nil && n.right != nil {
		// Случай когда удаляется элемент имеющий обоих потомков
		// сводится к случаю удаления элемента имеющего не более одного потомка
		// путём модификации дерева.

		// Ищем вершину со следующим значением ключа в правой ветви.
		c := n.right
		for c.left != nil {
			c = c.left
		}

		// Меняем её местами с удаляемой вершиной.
		n.value = c.value // Ключу было бы уместно не быть слишком "тяжёлым"
		n = c
		p = c.parent
		isRight = n.isRight()
	}

	switch {
	case n.left == nil && n.right == nil:
		// к слову, это единственная возможная конфигурация для красной n

		if !swapChild(p, n, nil) {
			// удаляется корень не имеющий потомков, это сразу на выход
			t.root = nil
			return
		}

		if n.red {
			// Удаление красной вершины не влияет на целостность структуры
			// красно-чёрных деревьев.
			return
		}

	case n.left == nil:
		// Случай когда нет левого потомка — единственный потомок чёрной
		// вершины может быть только красным, иначе нарушается структура
		// КЧ дерева: чёрная длина пустой ветви равна 1, чёрная длина непустой ветви
		// с чёрным узлом не меньше 2. Поэтому потомка надо перекрасить
		// в чёрный перед удалением чтобы соблюсти структуру.
		if !n.red {
			n.right.red = false
		}

		n.right.parent = p
		if !swapChild(p, n, n.right) {
			t.root = n.right
			if n.right != nil {
				n.right.red = false
			}
		}

		// Выходим, т.к. этот случай всегда приводит к корректному балансу.
		return

	case n.right == nil:
		// Случай когда нет левого потомка.
		// Соображения аналогичны предыдущему случаю.
		if !n.red {
			n.left.red = false
		}

		n.left.parent = p
		if !swapChild(p, n, n.left) {
			t.root = n.left
			if n.left != nil {
				n.left.red = false
			}
		}

		// Выходим, т.к. этот случай всегда приводит к корректному балансу.
		return
	}

	if p == nil {
		// удалённая вершина была корнем дерева то баланс корректен т.к.
		// структура поддерева не затронута
		return
	}

	// Здесь мы оказываемся только в случае когда у p был удалён
	// чёрный потомок, это неизбежно ведёт к нарушению структуры
	t.deleteFix(p, isRight)

	return true
}

// SaveSession сохранение сессии.
func (t *rbTree) SaveSession(repeat uint64, sess types.Session) {
	if t.root == nil {
		t.root = &rbTreeNode{
			value: &savedSessionsData{
				Repeat:   repeat,
				Sessions: []types.Session{sess},
			},
		}
		t.size = 1
		return
	}

	p, isRight, alreadyExist := rbTreeLookupForFreeValueParent(t.root, repeat)
	if alreadyExist {
		p.value.Sessions = append(p.value.Sessions, sess)
		return
	}

	// добавляем в дерево узел красного цвета
	n := &rbTreeNode{
		value: &savedSessionsData{
			Repeat:   repeat,
			Sessions: []types.Session{sess},
		},
		parent: p,
		red:    true,
	}
	if isRight {
		p.right = n
	} else {
		p.left = n
	}

	t.size++
	t.rebalanceInserted(p, n)
}

// swapChild поменять потомка в родителе с from на to.
// Возвращает false тогда и только тогда, когда выданный parent равен nil.
func swapChild(parent, from, to *rbTreeNode) bool {
	if parent == nil {
		return false
	}

	if parent.left == from {
		parent.left = to
	} else {
		parent.right = to
	}

	return true
}

// lToP перебалансировка дерева с вершиной в P
// с перемещением узла L на место P.
func (t *rbTree) lToP(p *rbTreeNode) {
	l := p.left

	l.parent, l.right, p.parent, p.left = p.parent, p, l, l.right

	if !swapChild(l.parent, p, l) {
		t.root = l
		l.red = false
	}
	if p.left != nil {
		p.left.parent = p
	}
}

// lrToP перебалансировка дерева с вершиной в P
// с перемещением узла LR на место P.
func (t *rbTree) lrToP(p *rbTreeNode) {
	l := p.left
	lr := p.left.right

	lr.parent, lr.left, lr.right, l.parent, l.right, p.parent, p.left =
		p.parent, l, p, lr, lr.left, lr, lr.right

	if !swapChild(lr.parent, p, lr) {
		t.root = lr
		lr.red = false
	}
	if p.left != nil {
		p.left.parent = p
	}
	if l.right != nil {
		l.right.parent = l
	}
}

// rToP перебалансировка дерева с вершиной в P
// с перемещением R на место P.
func (t *rbTree) rToP(p *rbTreeNode) {
	r := p.right

	r.parent, r.left, p.parent, p.right = p.parent, p, r, r.left

	if !swapChild(r.parent, p, r) {
		t.root = r
		r.red = false
	}
	if p.right != nil {
		p.right.parent = p
	}
}

// rlToP перебалансировка дерева с вершиной в P
// с перемещением RL на место P.
func (t *rbTree) rlToP(p *rbTreeNode) {
	r := p.right
	rl := p.right.left

	rl.parent, rl.left, rl.right, r.parent, r.left, p.parent, p.right =
		p.parent, p, r, rl, rl.right, rl, rl.left

	if !swapChild(rl.parent, p, rl) {
		t.root = rl
		rl.red = false
	}
	if p.right != nil {
		p.right.parent = p
	}
	if r.left != nil {
		r.left.parent = r
	}
}

// rbTreeNode узел дерева.
type rbTreeNode struct {
	value *savedSessionsData

	parent *rbTreeNode
	left   *rbTreeNode
	right  *rbTreeNode
	red    bool
}

func (n *rbTreeNode) isRight() bool {
	if n.parent == nil {
		return false
	}

	return n.parent.right == n
}

func (n *rbTreeNode) isRed() bool {
	if n == nil {
		return false
	}

	return n.red
}

func (n *rbTreeNode) olderRelatives() (p *rbTreeNode, b *rbTreeNode) {
	p = n.parent

	if p == nil {
		return nil, nil
	}

	if p.right == n {
		return p, p.left
	}

	return p, p.right
}

func (t *rbTree) deleteFix(p *rbTreeNode, isRight bool) {
	// Метка поставлена для того, чтобы избежать рекурсивных вызовов.
	// Можно было бы использовать цикл "пока x != nil", но это порождает
	// неудобную вложенность, без которой хотелось бы обойтись для лучшей
	// читаемости случаев. Поэтому просто устанавливаем новые значения
	// x и isRight и переходим на start.
start:

	if p == nil {
		return
	}

	if isRight {
		// Удаление из правого поддерева родителя.
		l := p.left

		switch {
		case p.red:
			// В этом случае левый узел всегда чёрный.

			switch {
			case l.right.isRed():
				t.lrToP(p)
				p.red = false
				return

			case l.left.isRed():
				t.lToP(p)
				return

			default:
				// Оба потомка левой ветви — чёрные.
				l.red = true
				p.red = false
				return
			}

		default:
			// Вершина — чёрная.

			switch {
			case l.isRed():
				lr := l.right
				switch {
				case lr.left.isRed():
					t.lrToP(p)
					l.right.red = false
					return

				case lr.right.isRed():
					t.lrToP(p)
					p = l
					isRight = true
					goto start

				default:
					t.lToP(p)
					p.red = false
					l.red = false
					p.left.red = true
					return
				}

			default:
				switch {
				case l.right.isRed():
					l.right.red = false
					t.lrToP(p)
					return
				case l.left.isRed():
					l.left.red = false
					t.lToP(p)
					return
				default:
					t.lToP(p)
					p.red = true
					if p.parent == nil {
						// дошли до конца, дальнейшая перебалансировка не нужна
						return
					}
					isRight = l.isRight()
					p = l.parent
					goto start
				}
			}
		}
	}

	// удалёние из левого поддерева родителя
	r := p.right
	switch {
	case p.red:
		// В этом случае левый узел всегда чёрный.

		switch {
		case r.left.isRed():
			t.rlToP(p)
			p.red = false
			return

		case r.right.isRed():
			t.rToP(p)
			return

		default:
			// Оба потомка левой ветви — чёрные.
			r.red = true
			p.red = false
			return
		}

	default:
		// Вершина — чёрная.

		switch {
		case r.isRed():
			rl := r.left

			switch {
			case rl.right.isRed():
				t.rlToP(p)
				r.left.red = false
				return

			case rl.left.isRed():
				t.rlToP(p)
				p = r
				isRight = false
				goto start

			default:
				t.rToP(p)
				p.red = false
				r.red = false
				p.right.red = true
				return
			}

		default:
			// Левый потомок — чёрный:
			switch {
			case r.left.isRed():
				r.left.red = false
				t.rlToP(p)
				return
			case r.right.isRed():
				r.right.red = false
				t.rToP(p)
				return
			default:
				t.rToP(p)
				p.red = true
				if p.parent == nil {
					// дошли до конца, дальнейшая перебалансировка не нужна
					return
				}
				isRight = r.isRight()
				p = r.parent
				goto start
			}
		}
	}
}

func (t *rbTree) rebalanceInserted(p *rbTreeNode, n *rbTreeNode) bool {
	for p.red {
		// Если родитель красный, то это означает, что он не является корнем
		// дерева, т.к. тот — чёрный, т.е. у него имеется родитель, которого назовём "дедушкой".
		g, u := p.olderRelatives()
		if g == nil {
			// родитель является корнем дерева, снова красим его в чёрный и выходим
			p.red = false
			return true
		}

		if u.isRed() {
			if u != nil {
				u.red = false
			}
			p.red = false
			g.red = true

			// После перекраски дедушки в красный может случиться проблема несоответствия его цвета
			// и цвета его родителя.
			p = g.parent
			n = g
			if p == nil {
				g.red = false
				return true
			}
			continue
		}

		switch {
		case !p.isRight() && !n.isRight():
			p.red = false
			g.red = true
			t.lToP(g)

		case !p.isRight() && n.isRight():
			n.red = false
			g.red = true
			t.lrToP(g)

		case p.isRight() && !n.isRight():
			n.red = false
			g.red = true
			t.rlToP(g)

		case p.isRight() && n.isRight():
			p.red = false
			g.red = true
			t.rToP(g)
		}

		return true
	}

	return true
}

type rbTreeIterator struct {
	n *rbTreeNode
	r *rbTreeNode

	justRaised bool
}

// Next проверка, что есть ещё непройденные узлы.
func (i *rbTreeIterator) Next() bool {
	if i.n == nil && i.r == nil {
		return false
	}

	if i.n == nil {
		i.n = i.r
		for i.n.left != nil {
			i.n = i.n.left
		}

		return true
	}

	if i.n.right != nil {
		i.n = i.n.right
		for i.n.left != nil {
			i.n = i.n.left
		}
		return true
	}

	for i.n.isRight() {
		i.n = i.n.parent
	}

	i.n = i.n.parent

	if i.n == nil {
		i.n = nil
		i.r = nil
		return false
	}

	return true
}

// Item отдать значение очередного узла.
func (i *rbTreeIterator) Item() *savedSessionsData {
	return i.n.value
}

func rbTreeLookupForFreeValueParent(n *rbTreeNode, repeat uint64) (_ *rbTreeNode, isRight bool, existing bool) {
	for {
		switch {
		case n.value.Repeat > repeat:
			if n.left == nil {
				return n, false, false
			}
			n = n.left

		case n.value.Repeat < repeat:
			if n.right == nil {
				return n, true, false
			}
			n = n.right

		default:
			return n, false, true
		}
	}
}

func rbTreeLookupForValue(n *rbTreeNode, repeat uint64) *rbTreeNode {
	for {
		switch {
		case repeat < n.value.Repeat:
			if n.left == nil {
				return nil
			}
			n = n.left

		case repeat > n.value.Repeat:
			if n.right == nil {
				return nil
			}
			n = n.right

		default:
			return n
		}
	}
}

func rbTreeAllocNode(
	mapping map[*rbTreeNode]*rbTreeNode,
	nodes []rbTreeNode,
	values []savedSessionsData,
	item *rbTreeNode,
	arenaIndex int,
) (_ *rbTreeNode, newArentIndex int) {
	if item == nil {
		return nil, arenaIndex
	}

	nitem, ok := mapping[item]
	if ok {
		return nitem, arenaIndex
	}

	nitem = &nodes[arenaIndex]
	nitem.value = &values[arenaIndex]
	nitem.value.Sessions = item.value.Sessions
	nitem.value.Repeat = item.value.Repeat
	mapping[item] = nitem

	return nitem, arenaIndex + 1
}
