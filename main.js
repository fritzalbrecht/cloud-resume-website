visitorCount = document.getElementById('visitors');

fetch('https://20sjf7lu58.execute-api.us-east-1.amazonaws.com/prod/putVisitors')
    .then(() => fetch('https://oe1nrmsfc1.execute-api.us-east-1.amazonaws.com/default/getVIsitors'))
    .then(response => response.json())
    .then(data => (visitorCount.innerHTML = (data)));
