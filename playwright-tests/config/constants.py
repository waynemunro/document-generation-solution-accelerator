from dotenv import load_dotenv
import os

load_dotenv()
URL = os.getenv('url')

if URL.endswith('/'):
    URL = URL[:-1]
    

# browse input data
browse_question1 = "What are typical sections in a promissory note?"
browse_question2 = "List the details of two promissory notes governed by the laws of the state of California"

# Grants input data
generate_question1 = "Generate promissory note with a proposed $100,000 for Washington State"
