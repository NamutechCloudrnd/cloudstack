let menuData = null

async function loadMenuData() {
  try {
    const response = await fetch('/guide/html/menu-data.json')
    menuData = await response.json()
    renderMenu()
    handleRouteChange()

    window.addEventListener('hashchange', handleRouteChange)
  } catch (error) {
    console.error('Failed to load menu data:', error)
  }
}

function renderMenu() {
  const sidebar = document.getElementById('menu-sidebar')
  if (!sidebar) return

  sidebar.innerHTML = ''
  sidebar.classList.add('menu-sidebar')

  const sidebarTitle = document.createElement('div')
  sidebarTitle.className = 'sidebar-top-link sidebar-top-link--static'
  sidebarTitle.innerHTML = '<i class="fa fa-book"></i><span>사용자 설명서</span>'
  sidebar.appendChild(sidebarTitle)

  menuData.menu.forEach((category) => {
    const accordion = createAccordionItem(category)
    sidebar.appendChild(accordion)
  })

  const usecaseLink = document.createElement('a')
  usecaseLink.className = 'sidebar-top-link'
  usecaseLink.href = '#/usecase'
  usecaseLink.dataset.path = 'usecase'
  usecaseLink.innerHTML = '<i class="fa fa-download"></i><span>Use Case</span>'
  sidebar.appendChild(usecaseLink)
}

function createAccordionItem(category) {
  const accordionDiv = document.createElement('div')
  accordionDiv.className = 'accordion-item'
  accordionDiv.id = `accordion-${category.id}`

  const header = document.createElement('div')
  header.className = 'accordion-header'
  const iconHTML = category.icon ? `<i class="fa ${category.icon}"></i>` : ''
  header.innerHTML = `
    <span class="accordion-icon">▶</span>
    ${iconHTML}
    <span class="accordion-label">${category.label}</span>
  `

  const content = document.createElement('div')
  content.className = 'accordion-content'

  const itemsList = document.createElement('div')
  itemsList.className = 'menu-items'

  category.items.forEach((item) => {
    const menuItem = document.createElement('div')
    menuItem.className = 'menu-item'
    menuItem.id = `menu-item-${item.id}`

    const link = document.createElement('a')
    link.href = `#/${item.path}`
    link.textContent = item.label
    link.dataset.path = item.path

    menuItem.appendChild(link)
    itemsList.appendChild(menuItem)
  })

  content.appendChild(itemsList)

  header.addEventListener('click', () => toggleAccordion(accordionDiv))

  accordionDiv.appendChild(header)
  accordionDiv.appendChild(content)

  return accordionDiv
}

function toggleAccordion(accordionDiv) {
  const isOpen = accordionDiv.classList.contains('open')

  accordionDiv.classList.add('animated')
  accordionDiv.classList.toggle('open')
}

function handleRouteChange() {
  let hash = window.location.hash.substring(1)
  const contentFrame = document.getElementById('content-frame')
  const defaultContent = document.getElementById('default-content')

  // Remove leading slash from hash if present
  if (hash.startsWith('/')) {
    hash = hash.substring(1)
  }

  if (!hash) {
    contentFrame.style.display = 'none'
    contentFrame.innerHTML = ''
    defaultContent.style.display = 'block'
    highlightCurrentPage('')
  } else {
    const filePath = `/guide/html/${hash}${hash.endsWith('.html') ? '' : '.html'}`
    loadContent(filePath, contentFrame, defaultContent)
    highlightCurrentPage(hash)
  }
}

async function loadContent(filePath, contentFrame, defaultContent) {
  try {
    const response = await fetch(filePath)
    if (!response.ok) {
      showNotFound(contentFrame, defaultContent)
      return
    }

    const html = await response.text()
    contentFrame.innerHTML = html
    contentFrame.style.display = 'block'
    defaultContent.style.display = 'none'
    contentFrame.scrollTop = 0
  } catch (e) {
    showNotFound(contentFrame, defaultContent)
  }
}

function showNotFound(contentFrame, defaultContent) {
  contentFrame.style.display = 'none'
  contentFrame.innerHTML = ''
  defaultContent.style.display = 'block'

  const notFoundHTML = `
    <div style="padding: 2rem;">
      <h1>404 - 페이지를 찾을 수 없습니다</h1>
      <p>요청하신 페이지가 존재하지 않습니다.</p>
      <button onclick="window.location.hash=''" style="padding: 0.5rem 1rem; background-color: #007bff; color: white; border: none; border-radius: 4px; cursor: pointer;">
        돌아가기
      </button>
    </div>
  `

  defaultContent.innerHTML = notFoundHTML
}

function highlightCurrentPage(currentHash) {
  if (!menuData) return

  const menuItems = document.querySelectorAll('.menu-item')
  menuItems.forEach((item) => item.classList.remove('active'))

  const accordions = document.querySelectorAll('.accordion-item')
  accordions.forEach((item) => item.classList.remove('open'))

  const topLinks = document.querySelectorAll('.sidebar-top-link')
  topLinks.forEach((link) => link.classList.remove('active'))

  if (!currentHash) return

  const matchedTopLink = document.querySelector(`.sidebar-top-link[data-path="${currentHash}"]`)
  if (matchedTopLink) {
    matchedTopLink.classList.add('active')
    return
  }

  for (const category of menuData.menu) {
    for (const item of category.items) {
      if (item.path === currentHash) {
        const menuItem = document.getElementById(`menu-item-${item.id}`)
        const accordionItem = document.getElementById(`accordion-${category.id}`)

        if (menuItem) {
          menuItem.classList.add('active')
        }

        if (accordionItem) {
          accordionItem.classList.add('open')
        }

        return
      }
    }
  }
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', loadMenuData)
} else {
  loadMenuData()
}
