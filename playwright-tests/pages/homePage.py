from base.base import BasePage

class HomePage(BasePage):
    BROWSE_BUTTON = "//p[contains(text(),'Let AI search through your files and provide answe')]"



    def __init__(self, page):
        self.page = page

    def click_browse_button(self):
        # click on BROWSE 
        self.page.wait_for_timeout(3000)    
        self.page.locator(self.BROWSE_BUTTON).click()
        self.page.wait_for_timeout(5000)