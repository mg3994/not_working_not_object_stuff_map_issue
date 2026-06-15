# not_working_not_object_stuff_map_issue

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<!DOCTYPE html>
<html xmlns='http://www.w3.org/1999/xhtml' xmlns:b='http://www.google.com/2005/gml/b' xmlns:data='http://www.google.com/2005/gml/data' xmlns:expr='http://www.google.com/2005/gml/expr'>
<head>
  <title>Blogger Template with B-Skin</title>
  
  <b:skin><![CDATA[
    
      body {
        font-family: Arial, sans-serif;
        background-color: #f4f4f4;
        padding: 40px;
      }
      .result-box {
        background: #fff;
        padding: 20px;
        border-radius: 8px;
        box-shadow: 0 2px 5px rgba(0,0,0,0.1);
      }
    
  ]]></b:skin>
</head>
<body>
<div>
<b:with value='&quot;anyrandom|anddynamic&quot;' var='fullText'> 
  <b:loop index='charIndex' values='data:fullText map (char =&gt; char)' var='char'>
    <b:if cond='data:char contains &quot;|&quot;'> 
      <b:with value='data:charIndex' var='delimiterPos'>
      <!-- LEFT PART (before |) --> 
      <b:eval expr='data:fullText snippet { length: data:delimiterPos, links: false, linebreaks: false }'/> 
      <!-- RIGHT PART (after |) --> 
      <b:eval expr='data:fullText snippet { length: data:fullText.length - data:delimiterPos - 1, links: false, linebreaks: false }'/> 
      </b:with> 
    </b:if> 
  </b:loop> 
  </b:with>
  </div>
<b:section id='main'/>
</body>
</html>
```
