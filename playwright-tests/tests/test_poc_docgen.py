from pages.draftPage import DraftPage
from pages.browsePage import BrowsePage
from pages.generatePage import GeneratePage
from pages.homePage import HomePage
from config.constants import *

def test_DKM_GOLDENPATH(login_logout):
    page = login_logout
    home_page = HomePage(page)
    # validate page title
    home_page.click_browse_button()
    browse_page = BrowsePage(page)
    browse_page.enter_a_question(browse_question1)
    browse_page.click_send_button()
    # validate response 
    browse_page.validate_response_status(question_api=browse_question1)
    browse_page.click_expand_reference_in_response()
    browse_page.click_reference_link_in_response()
    browse_page.close_citation()

    browse_page.enter_a_question(browse_question2)
    browse_page.click_send_button()
    browse_page.click_expand_reference_in_response()
    browse_page.click_reference_link_in_response()
    browse_page.close_citation()
    # # validate response
    browse_page.click_generate_button()
    browse_page.validate_response_status(question_api=browse_question2)
    generate_page = GeneratePage(page)
    generate_page.enter_a_question(generate_question1)
    generate_page.click_send_button()
    generate_page.click_generate_draft_button()
    generate_page.validate_response_status(question_api=generate_question1)
    draft_page = DraftPage(page)
    draft_page.check_draft_Sections()
    
